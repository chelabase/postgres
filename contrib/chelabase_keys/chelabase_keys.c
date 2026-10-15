/*-------------------------------------------------------------------------
 *
 * chelabase_keys.c
 *		  Logical decoding output plugin that reports, for each committed
 *		  transaction that changed rows, the primary keys of the changed rows.
 *
 * One compact JSON message per committed transaction with row changes,
 * written at commit:
 *
 *	 {"v":1,"lsn":"X/Y","xid":<full xid>,"changes":[
 *	   {"rel":<oid>,"s":"<schema>","t":"<table>","op":"i"|"u"|"d","k":[[...],...]},
 *	   {"rel":<oid>,"s":"<schema>","t":"<table>","op":"c"}]}
 *
 * or {"v":1,"lsn":"X/Y","xid":<full xid>,"all":true} once the transaction
 * goes past one of the bounds (max_tables, max_message_bytes).  The
 * max_message_bytes budget counts each listed key's memory overhead
 * (KEY_MEMORY_OVERHEAD) besides the message text, so it also bounds the
 * memory a transaction's keys take.
 *
 * Relations appear in the order of their first change; within a relation
 * the ops come in the order i, u, d (or a single c); keys come in the order
 * first seen, at most once per (relation, op).  A relation gets keys only
 * when its replica identity is its primary key; otherwise, or past
 * max_keys_per_table distinct keys, or after a TRUNCATE, it is "c".
 *
 * Key values are printed by each type's output function under fixed
 * output settings (DateStyle, TimeZone, IntervalStyle, extra_float_digits,
 * bytea_output, lc_monetary, search_path), set once per transaction in
 * begin_cb and restored in commit_cb, so the session, database and role
 * settings never change the form of a key.
 *
 * Every string in a message (keys, schema and table names) is UTF-8,
 * converted from the database encoding; a SQL_ASCII database has no
 * encoding to convert from and is refused when the plugin starts.
 *
 * There are no stream callbacks (a transaction is decoded at its commit;
 * large ones spill to disk) and no prepare callbacks (a prepared
 * transaction is decoded at COMMIT PREPARED).
 *
 * Copyright (c) 2026, Chelabase
 *
 * IDENTIFICATION
 *		  contrib/chelabase_keys/chelabase_keys.c
 *
 *-------------------------------------------------------------------------
 */
#include "postgres.h"

#include <limits.h>

#include "access/htup_details.h"
#include "access/transam.h"
#include "access/xlogdefs.h"
#include "common/hashfn.h"
#include "fmgr.h"
#include "lib/stringinfo.h"
#include "mb/pg_wchar.h"
#include "replication/logical.h"
#include "replication/output_plugin.h"
#include "replication/reorderbuffer.h"
#include "utils/guc.h"
#include "utils/hsearch.h"
#include "utils/json.h"
#include "utils/lsyscache.h"
#include "utils/memutils.h"
#include "utils/rel.h"
#include "utils/relcache.h"
#include "varatt.h"

PG_MODULE_MAGIC;

/* Ops, in output order. */
#define OP_I 0
#define OP_U 1
#define OP_D 2
#define NUM_KEY_OPS 3

static const char op_names[NUM_KEY_OPS] = {'i', 'u', 'd'};

/* Option ranges (S3, RT3-3). */
#define MAX_KEYS_PER_TABLE_MIN 1
#define MAX_KEYS_PER_TABLE_MAX 10000
#define MAX_KEYS_PER_TABLE_DEFAULT 1000
#define MAX_TABLES_MIN 1
#define MAX_TABLES_MAX 1000
#define MAX_TABLES_DEFAULT 256
#define MAX_MESSAGE_BYTES_MIN 65536
#define MAX_MESSAGE_BYTES_MAX 16777216
#define MAX_MESSAGE_BYTES_DEFAULT 1048576

/*
 * The longest message header and trailer: the widest LSN and full xid, with
 * the "changes" array's brackets.  Used as an upper bound for the budget.
 */
#define MESSAGE_FRAME_MAX \
	(sizeof("{\"v\":1,\"lsn\":\"FFFFFFFF/FFFFFFFF\",\"xid\":18446744073709551615,\"changes\":[]}") - 1)

/* Lengths of the fixed pieces of one op group. */
#define OP_PIECE_LEN	(sizeof(",\"op\":\"i\"") - 1)	/* after the relation prefix */
#define KEYS_OPEN_LEN	(sizeof(",\"k\":[") - 1)
#define KEYS_CLOSE_LEN	(sizeof("]}") - 1)
#define C_CLOSE_LEN		(sizeof("}") - 1)

/* One distinct key of a relation in the current transaction. */
typedef struct KeyEntry
{
	char	   *key;			/* hash key: the key's JSON array text */
	uint8		ops;			/* bit per op the key was seen under */
} KeyEntry;

/*
 * T2 m2: the memory a key costs besides its text, counted in the budget for
 * each op it is listed under, so that max_message_bytes bounds the memory a
 * transaction's keys take and not only the message's text: its hash entry
 * (dynahash's element header and the KeyEntry), its list cell and the chunk
 * header of its text's allocation.  (The text itself is counted once per op;
 * its allocation can round it up to twice that.)
 */
#define KEY_MEMORY_OVERHEAD \
	(MAXALIGN(sizeof(HASHELEMENT)) + MAXALIGN(sizeof(KeyEntry)) + \
	 sizeof(ListCell) + sizeof(uint64))

/* One relation touched by the current transaction. */
typedef struct RelEntry
{
	Oid			relid;			/* hash key */
	bool		is_c;			/* keys dropped: the relation is "c" */
	char	   *prefix;			/* {"rel":<oid>,"s":"<s>","t":"<t>" */
	int			prefix_len;
	MemoryContext kcxt;			/* holds keyhash and the key texts */
	HTAB	   *keyhash;		/* distinct keys, all ops together */
	List	   *keys[NUM_KEY_OPS];	/* char * key texts, first-seen order */
	int64		key_bytes[NUM_KEY_OPS]; /* sum of the key texts' lengths */
	int64		size;			/* this relation's part of the budget */
} RelEntry;

typedef struct ChelabaseKeysData
{
	/* options */
	int			max_keys_per_table;
	int			max_tables;
	int			max_message_bytes;

	MemoryContext change_cxt;	/* per change scratch, reset after each */
	MemoryContext txn_cxt;		/* per transaction, reset at commit */

	/* the transaction being decoded */
	int			guc_nestlevel;	/* 0 when the output settings aren't set */
	bool		all;			/* past max_tables or max_message_bytes */
	HTAB	   *rels;			/* Oid -> RelEntry */
	List	   *rel_order;		/* RelEntry *, first-change order */
	int			nrels;
	int64		size;			/* the budget: an upper bound of the message
								 * length and of the keys' memory */
} ChelabaseKeysData;

/* Result of reading a key from a tuple. */
typedef enum KeyResult
{
	KEY_OK,
	KEY_TOAST,					/* a key column is an unchanged TOAST pointer */
	KEY_MISSING,				/* no tuple, or a key column is NULL */
} KeyResult;

/* Options, for the "given more than once" check. */
#define OPT_MAX_KEYS_PER_TABLE	0x01
#define OPT_MAX_TABLES			0x02
#define OPT_MAX_MESSAGE_BYTES	0x04

static void ck_startup(LogicalDecodingContext *ctx, OutputPluginOptions *opt,
					   bool is_init);
static void ck_shutdown(LogicalDecodingContext *ctx);
static void ck_begin_txn(LogicalDecodingContext *ctx, ReorderBufferTXN *txn);
static void ck_commit_txn(LogicalDecodingContext *ctx, ReorderBufferTXN *txn,
						  XLogRecPtr commit_lsn);
static void ck_change(LogicalDecodingContext *ctx, ReorderBufferTXN *txn,
					  Relation relation, ReorderBufferChange *change);
static void ck_truncate(LogicalDecodingContext *ctx, ReorderBufferTXN *txn,
						int nrelations, Relation relations[],
						ReorderBufferChange *change);

void
_PG_output_plugin_init(OutputPluginCallbacks *cb)
{
	cb->startup_cb = ck_startup;
	cb->begin_cb = ck_begin_txn;
	cb->change_cb = ck_change;
	cb->truncate_cb = ck_truncate;
	cb->commit_cb = ck_commit_txn;
	cb->shutdown_cb = ck_shutdown;
}

/*
 * Parse an integer option value in [lo, hi], or raise the option's error.
 * T2 m1: the value is decimal digits only: no sign, no leading or trailing
 * space.
 */
static int
parse_int_option(DefElem *elem, int lo, int hi)
{
	const char *raw;
	char	   *end;
	long		val;

	if (elem->arg == NULL)
		goto bad;
	raw = strVal(elem->arg);
	if (*raw == '\0')
		goto bad;
	for (const char *p = raw; *p != '\0'; p++)
		if (*p < '0' || *p > '9')
			goto bad;
	errno = 0;
	val = strtol(raw, &end, 10);
	if (errno != 0 || *end != '\0' || val < lo || val > hi)
		goto bad;
	return (int) val;

bad:
	ereport(ERROR,
			(errcode(ERRCODE_INVALID_PARAMETER_VALUE),
			 errmsg("chelabase_keys: option \"%s\" must be an integer between %d and %d",
					elem->defname, lo, hi)));
	pg_unreachable();
}

/*
 * T2 m1: each option is given at most once.
 */
static void
check_once(DefElem *elem, int *seen, int bit)
{
	if (*seen & bit)
		ereport(ERROR,
				(errcode(ERRCODE_INVALID_PARAMETER_VALUE),
				 errmsg("chelabase_keys: option \"%s\" is given more than once",
						elem->defname)));
	*seen |= bit;
}

static void
ck_startup(LogicalDecodingContext *ctx, OutputPluginOptions *opt, bool is_init)
{
	ChelabaseKeysData *data;
	ListCell   *option;
	int			seen = 0;

	/*
	 * U4: messages are UTF-8.  A SQL_ASCII database's text has no known
	 * encoding, so it can't be converted: refuse it here, at slot creation
	 * (is_init) as at every start.
	 */
	if (GetDatabaseEncoding() == PG_SQL_ASCII)
		ereport(ERROR,
				(errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
				 errmsg("chelabase_keys: database encoding \"%s\" can't be converted to UTF-8",
						GetDatabaseEncodingName())));

	data = palloc0(sizeof(ChelabaseKeysData));
	data->max_keys_per_table = MAX_KEYS_PER_TABLE_DEFAULT;
	data->max_tables = MAX_TABLES_DEFAULT;
	data->max_message_bytes = MAX_MESSAGE_BYTES_DEFAULT;

	/*
	 * At slot creation (is_init) there are no options; at START_REPLICATION
	 * or pg_logical_slot_*_changes they are the client's.
	 */
	foreach(option, ctx->output_plugin_options)
	{
		DefElem    *elem = lfirst(option);

		Assert(elem->arg == NULL || IsA(elem->arg, String));

		if (strcmp(elem->defname, "max_keys_per_table") == 0)
		{
			check_once(elem, &seen, OPT_MAX_KEYS_PER_TABLE);
			data->max_keys_per_table =
				parse_int_option(elem, MAX_KEYS_PER_TABLE_MIN, MAX_KEYS_PER_TABLE_MAX);
		}
		else if (strcmp(elem->defname, "max_tables") == 0)
		{
			check_once(elem, &seen, OPT_MAX_TABLES);
			data->max_tables =
				parse_int_option(elem, MAX_TABLES_MIN, MAX_TABLES_MAX);
		}
		else if (strcmp(elem->defname, "max_message_bytes") == 0)
		{
			check_once(elem, &seen, OPT_MAX_MESSAGE_BYTES);
			data->max_message_bytes =
				parse_int_option(elem, MAX_MESSAGE_BYTES_MIN, MAX_MESSAGE_BYTES_MAX);
		}
		else
			ereport(ERROR,
					(errcode(ERRCODE_INVALID_PARAMETER_VALUE),
					 errmsg("chelabase_keys: unknown option \"%s\"",
							elem->defname)));
	}

	data->change_cxt = AllocSetContextCreate(ctx->context,
											 "chelabase_keys change context",
											 ALLOCSET_DEFAULT_SIZES);
	data->txn_cxt = AllocSetContextCreate(ctx->context,
										  "chelabase_keys transaction context",
										  ALLOCSET_DEFAULT_SIZES);

	ctx->output_plugin_private = data;

	opt->output_type = OUTPUT_PLUGIN_TEXTUAL_OUTPUT;
	opt->receive_rewrites = false;
}

static void
ck_shutdown(LogicalDecodingContext *ctx)
{
	ChelabaseKeysData *data = ctx->output_plugin_private;

	if (data == NULL)
		return;
	MemoryContextDelete(data->change_cxt);
	MemoryContextDelete(data->txn_cxt);
}

/*
 * Forget the transaction's collected state (its memory is in txn_cxt).
 */
static void
reset_txn_state(ChelabaseKeysData *data)
{
	MemoryContextReset(data->txn_cxt);
	data->rels = NULL;
	data->rel_order = NIL;
	data->nrels = 0;
	data->size = MESSAGE_FRAME_MAX;
}

/*
 * R6/RT3-8: one output form for keys, whatever the session, database or
 * role set.  Set once per transaction with GUC_ACTION_SAVE in a new GUC
 * nest level; commit_cb pops it, and an error in between is unwound by
 * the abort of the transaction decoding runs in.
 */
static int
set_output_settings(void)
{
	int			nestlevel = NewGUCNestLevel();

	(void) set_config_option("datestyle", "ISO, YMD",
							 PGC_USERSET, PGC_S_SESSION,
							 GUC_ACTION_SAVE, true, 0, false);
	(void) set_config_option("timezone", "UTC",
							 PGC_USERSET, PGC_S_SESSION,
							 GUC_ACTION_SAVE, true, 0, false);
	(void) set_config_option("intervalstyle", "iso_8601",
							 PGC_USERSET, PGC_S_SESSION,
							 GUC_ACTION_SAVE, true, 0, false);
	(void) set_config_option("extra_float_digits", "3",
							 PGC_USERSET, PGC_S_SESSION,
							 GUC_ACTION_SAVE, true, 0, false);
	(void) set_config_option("bytea_output", "hex",
							 PGC_USERSET, PGC_S_SESSION,
							 GUC_ACTION_SAVE, true, 0, false);
	(void) set_config_option("lc_monetary", "C",
							 PGC_USERSET, PGC_S_SESSION,
							 GUC_ACTION_SAVE, true, 0, false);
	(void) set_config_option("search_path", "",
							 PGC_USERSET, PGC_S_SESSION,
							 GUC_ACTION_SAVE, true, 0, false);

	return nestlevel;
}

static void
ck_begin_txn(LogicalDecodingContext *ctx, ReorderBufferTXN *txn)
{
	ChelabaseKeysData *data = ctx->output_plugin_private;

	data->all = false;
	reset_txn_state(data);
	data->guc_nestlevel = set_output_settings();
}

/* ---- per-relation bookkeeping ---- */

static uint32
key_hash(const void *key, Size keysize)
{
	const char *s = *(char *const *) key;

	return hash_bytes((const unsigned char *) s, strlen(s));
}

static int
key_match(const void *key1, const void *key2, Size keysize)
{
	return strcmp(*(char *const *) key1, *(char *const *) key2);
}

/*
 * Bytes this relation adds to the message's "changes" array, separators
 * between its own groups included, plus each listed key's memory overhead.
 */
static int64
rel_size(RelEntry *re)
{
	int64		size = 0;
	int			groups = 0;

	if (re->is_c)
		return re->prefix_len + OP_PIECE_LEN + C_CLOSE_LEN;

	for (int op = 0; op < NUM_KEY_OPS; op++)
	{
		int			n = list_length(re->keys[op]);

		if (n == 0)
			continue;
		size += re->prefix_len + OP_PIECE_LEN + KEYS_OPEN_LEN +
			re->key_bytes[op] + (n - 1) + KEYS_CLOSE_LEN +
			(int64) n * KEY_MEMORY_OVERHEAD;
		groups++;
	}
	if (groups > 1)
		size += groups - 1;
	return size;
}

/*
 * Recompute the relation's size after a change to it, and switch to "all"
 * when the message would go past max_message_bytes.  Returns false when the
 * transaction is now "all" (and the relation entry is gone).
 */
static bool
update_size(ChelabaseKeysData *data, RelEntry *re)
{
	int64		new_size = rel_size(re);

	data->size += new_size - re->size;
	re->size = new_size;
	if (data->size > data->max_message_bytes)
	{
		data->all = true;
		reset_txn_state(data);
		return false;
	}
	return true;
}

/*
 * Drop the relation's keys: it is "c" from now on.
 */
static bool
mark_c(ChelabaseKeysData *data, RelEntry *re)
{
	if (re->is_c)
		return true;
	re->is_c = true;
	MemoryContextDelete(re->kcxt);
	re->kcxt = NULL;
	re->keyhash = NULL;
	for (int op = 0; op < NUM_KEY_OPS; op++)
	{
		re->keys[op] = NIL;
		re->key_bytes[op] = 0;
	}
	return update_size(data, re);
}

/*
 * Append a string of the database encoding as a JSON string in UTF-8 (U4).
 * Converted before escaping, so escape_json sees only UTF-8.
 */
static void
append_json_utf8(StringInfo out, const char *s)
{
	char	   *u = pg_server_to_any(s, strlen(s), PG_UTF8);

	escape_json(out, u);
	if (u != s)
		pfree(u);
}

/*
 * The relation's entry in this transaction, made on its first change.
 * Returns NULL when the transaction is (now) "all".
 */
static RelEntry *
get_rel(ChelabaseKeysData *data, Relation relation)
{
	Oid			relid = RelationGetRelid(relation);
	RelEntry   *re;
	bool		found;
	MemoryContext old;
	StringInfoData buf;
	char	   *nspname;

	if (data->all)
		return NULL;

	if (data->rels == NULL)
	{
		HASHCTL		hctl;

		hctl.keysize = sizeof(Oid);
		hctl.entrysize = sizeof(RelEntry);
		hctl.hcxt = data->txn_cxt;
		data->rels = hash_create("chelabase_keys relations", 32, &hctl,
								 HASH_ELEM | HASH_BLOBS | HASH_CONTEXT);
	}

	re = hash_search(data->rels, &relid, HASH_FIND, NULL);
	if (re != NULL)
		return re;

	if (data->nrels + 1 > data->max_tables)
	{
		data->all = true;
		reset_txn_state(data);
		return NULL;
	}

	re = hash_search(data->rels, &relid, HASH_ENTER, &found);
	Assert(!found);

	old = MemoryContextSwitchTo(data->txn_cxt);

	re->is_c = false;
	re->size = 0;
	for (int op = 0; op < NUM_KEY_OPS; op++)
	{
		re->keys[op] = NIL;
		re->key_bytes[op] = 0;
	}

	nspname = get_namespace_name(RelationGetNamespace(relation));
	initStringInfo(&buf);
	appendStringInfo(&buf, "{\"rel\":%u,\"s\":", relid);
	append_json_utf8(&buf, nspname ? nspname : "");
	appendStringInfoString(&buf, ",\"t\":");
	append_json_utf8(&buf, RelationGetRelationName(relation));
	re->prefix = buf.data;
	re->prefix_len = buf.len;

	re->kcxt = AllocSetContextCreate(data->txn_cxt,
									 "chelabase_keys relation keys",
									 ALLOCSET_SMALL_SIZES);
	{
		HASHCTL		hctl;

		hctl.keysize = sizeof(char *);
		hctl.entrysize = sizeof(KeyEntry);
		hctl.hash = key_hash;
		hctl.match = key_match;
		hctl.hcxt = re->kcxt;
		re->keyhash = hash_create("chelabase_keys keys", 16, &hctl,
								  HASH_ELEM | HASH_FUNCTION | HASH_COMPARE |
								  HASH_CONTEXT);
	}

	data->rel_order = lappend(data->rel_order, re);

	MemoryContextSwitchTo(old);

	/* the separator before this relation's part */
	if (data->nrels > 0)
		data->size += 1;
	data->nrels++;

	return re;
}

/*
 * Record a key under an op.  Returns false when the transaction is (now)
 * "all".
 */
static bool
add_key(ChelabaseKeysData *data, RelEntry *re, int op, const char *key)
{
	KeyEntry   *ke;
	bool		found;
	char	   *lookup = (char *) key;

	if (re->is_c)
		return true;

	ke = hash_search(re->keyhash, &lookup, HASH_ENTER, &found);
	if (!found)
	{
		ke->key = MemoryContextStrdup(re->kcxt, key);
		ke->ops = 0;

		/* a relation's distinct keys, all ops together (RT3-3) */
		if (hash_get_num_entries(re->keyhash) > data->max_keys_per_table)
			return mark_c(data, re);
	}

	if (ke->ops & (1 << op))
		return true;
	ke->ops |= (1 << op);
	{
		MemoryContext old = MemoryContextSwitchTo(re->kcxt);

		re->keys[op] = lappend(re->keys[op], ke->key);
		MemoryContextSwitchTo(old);
	}
	re->key_bytes[op] += strlen(ke->key);
	return update_size(data, re);
}

/* ---- keys ---- */

/*
 * The relation's primary key columns, in the index's column order, when
 * its replica identity is the primary key: relreplident 'd' with a primary
 * key, or 'i' on the primary key index.  Returns the number of columns,
 * or 0 when the relation gets no keys.
 */
static int
pk_attnums(Relation relation, AttrNumber **attnums)
{
	Oid			pkoid;
	Relation	idx;
	int			n;
	char		ident = relation->rd_rel->relreplident;

	if (ident != REPLICA_IDENTITY_DEFAULT && ident != REPLICA_IDENTITY_INDEX)
		return 0;

	pkoid = RelationGetPrimaryKeyIndex(relation);
	if (!OidIsValid(pkoid))
		return 0;
	if (ident == REPLICA_IDENTITY_INDEX &&
		RelationGetReplicaIndex(relation) != pkoid)
		return 0;

	idx = RelationIdGetRelation(pkoid);
	if (!RelationIsValid(idx))
		return 0;
	n = idx->rd_index->indnkeyatts;
	*attnums = palloc(sizeof(AttrNumber) * n);
	for (int i = 0; i < n; i++)
		(*attnums)[i] = idx->rd_index->indkey.values[i];
	RelationClose(idx);

	for (int i = 0; i < n; i++)
		if ((*attnums)[i] <= 0)
			return 0;			/* not a plain column; can't be a PK */
	return n;
}

/*
 * The key columns of a tuple: cols[i] is the i-th key column's text output
 * as a JSON string (UTF-8), or NULL when the column is an unchanged TOAST
 * pointer (its value isn't in the record; KEY_TOAST).
 */
static KeyResult
tuple_key_cols(Relation relation, HeapTuple tuple, AttrNumber *attnums,
			   int nkeys, char **cols)
{
	TupleDesc	tupdesc = RelationGetDescr(relation);
	KeyResult	res = KEY_OK;

	if (tuple == NULL)
		return KEY_MISSING;

	for (int i = 0; i < nkeys; i++)
	{
		AttrNumber	attnum = attnums[i];
		Form_pg_attribute attr;
		Datum		value;
		bool		isnull;
		Oid			typoutput;
		bool		typisvarlena;
		StringInfoData col;

		if (attnum > tupdesc->natts)
			return KEY_MISSING;
		attr = TupleDescAttr(tupdesc, attnum - 1);
		if (attr->attisdropped)
			return KEY_MISSING;

		value = heap_getattr(tuple, attnum, tupdesc, &isnull);
		if (isnull)
			return KEY_MISSING;

		getTypeOutputInfo(attr->atttypid, &typoutput, &typisvarlena);
		if (typisvarlena && VARATT_IS_EXTERNAL_ONDISK(DatumGetPointer(value)))
		{
			/* unchanged TOASTed value: not in the record */
			cols[i] = NULL;
			res = KEY_TOAST;
			continue;
		}

		initStringInfo(&col);
		append_json_utf8(&col, OidOutputFunctionCall(typoutput, value));
		cols[i] = col.data;
	}
	return res;
}

/*
 * A key as a JSON array of its columns, e.g. ["1","x"].
 */
static void
join_key(char **cols, int nkeys, StringInfo out)
{
	resetStringInfo(out);
	appendStringInfoChar(out, '[');
	for (int i = 0; i < nkeys; i++)
	{
		Assert(cols[i] != NULL);
		if (i > 0)
			appendStringInfoChar(out, ',');
		appendStringInfoString(out, cols[i]);
	}
	appendStringInfoChar(out, ']');
}

static void
ck_change(LogicalDecodingContext *ctx, ReorderBufferTXN *txn,
		  Relation relation, ReorderBufferChange *change)
{
	ChelabaseKeysData *data = ctx->output_plugin_private;
	MemoryContext old;
	RelEntry   *re;
	AttrNumber *attnums = NULL;
	int			nkeys;
	StringInfoData newkey;
	StringInfoData oldkey;
	char	  **newcols;
	char	  **oldcols;
	KeyResult	nres;
	KeyResult	ores;

	if (data->all)
		return;

	old = MemoryContextSwitchTo(data->change_cxt);

	re = get_rel(data, relation);
	if (re == NULL || re->is_c)
		goto done;

	nkeys = pk_attnums(relation, &attnums);
	if (nkeys == 0)
	{
		mark_c(data, re);
		goto done;
	}

	initStringInfo(&newkey);
	initStringInfo(&oldkey);
	newcols = palloc0(sizeof(char *) * nkeys);
	oldcols = palloc0(sizeof(char *) * nkeys);

	switch (change->action)
	{
		case REORDER_BUFFER_CHANGE_INSERT:
			nres = tuple_key_cols(relation, change->data.tp.newtuple, attnums, nkeys, newcols);
			if (nres == KEY_OK)
			{
				join_key(newcols, nkeys, &newkey);
				add_key(data, re, OP_I, newkey.data);
			}
			else
				mark_c(data, re);
			break;

		case REORDER_BUFFER_CHANGE_UPDATE:
			nres = tuple_key_cols(relation, change->data.tp.newtuple, attnums, nkeys, newcols);
			if (change->data.tp.oldtuple != NULL)
			{
				/*
				 * Postgres logs the old key when a key column changed or is
				 * stored externally (flattened, for the latter).  A key
				 * column that is an unchanged TOAST pointer in the new tuple
				 * has the old key's value (T2 I1), so the new key is built
				 * column by column from both.  Equal key texts are an update
				 * of that key; different ones are a delete and an insert
				 * (RT3-9).
				 */
				ores = tuple_key_cols(relation, change->data.tp.oldtuple, attnums, nkeys, oldcols);
				if (ores != KEY_OK || nres == KEY_MISSING)
				{
					mark_c(data, re);
					break;
				}
				for (int i = 0; i < nkeys; i++)
					if (newcols[i] == NULL)
						newcols[i] = oldcols[i];
				join_key(oldcols, nkeys, &oldkey);
				join_key(newcols, nkeys, &newkey);
				if (strcmp(oldkey.data, newkey.data) == 0)
					add_key(data, re, OP_U, oldkey.data);
				else if (add_key(data, re, OP_D, oldkey.data))
					add_key(data, re, OP_I, newkey.data);
			}
			else if (nres == KEY_OK)
			{
				join_key(newcols, nkeys, &newkey);
				add_key(data, re, OP_U, newkey.data);
			}
			else
				mark_c(data, re);
			break;

		case REORDER_BUFFER_CHANGE_DELETE:
			ores = tuple_key_cols(relation, change->data.tp.oldtuple, attnums, nkeys, oldcols);
			if (ores == KEY_OK)
			{
				join_key(oldcols, nkeys, &oldkey);
				add_key(data, re, OP_D, oldkey.data);
			}
			else
				mark_c(data, re);
			break;

		default:
			/* not a row change this plugin reports; be safe */
			mark_c(data, re);
			break;
	}

done:
	MemoryContextSwitchTo(old);
	MemoryContextReset(data->change_cxt);
}

static void
ck_truncate(LogicalDecodingContext *ctx, ReorderBufferTXN *txn,
			int nrelations, Relation relations[], ReorderBufferChange *change)
{
	ChelabaseKeysData *data = ctx->output_plugin_private;
	MemoryContext old;

	if (data->all)
		return;

	old = MemoryContextSwitchTo(data->change_cxt);
	for (int i = 0; i < nrelations; i++)
	{
		RelEntry   *re = get_rel(data, relations[i]);

		if (re == NULL)
			break;
		if (!mark_c(data, re))
			break;
	}
	MemoryContextSwitchTo(old);
	MemoryContextReset(data->change_cxt);
}

/* ---- the message ---- */

static void
append_keys(StringInfo out, List *keys)
{
	ListCell   *lc;
	bool		first = true;

	foreach(lc, keys)
	{
		if (!first)
			appendStringInfoChar(out, ',');
		appendStringInfoString(out, (const char *) lfirst(lc));
		first = false;
	}
}

static void
ck_commit_txn(LogicalDecodingContext *ctx, ReorderBufferTXN *txn,
			  XLogRecPtr commit_lsn)
{
	ChelabaseKeysData *data = ctx->output_plugin_private;

	if (data->all || data->nrels > 0)
	{
		FullTransactionId fxid;
		StringInfo	out;
		ListCell   *lc;
		bool		first_group = true;

		/* RT3-2: the full transaction id, comparable with pg_current_xact_id() */
		fxid = FullTransactionIdFromAllowableAt(ReadNextFullTransactionId(),
												txn->xid);

		OutputPluginPrepareWrite(ctx, true);
		out = ctx->out;
		appendStringInfo(out, "{\"v\":1,\"lsn\":\"%X/%X\",\"xid\":" UINT64_FORMAT,
						 LSN_FORMAT_ARGS(txn->end_lsn),
						 U64FromFullTransactionId(fxid));

		if (data->all)
			appendStringInfoString(out, ",\"all\":true}");
		else
		{
#ifdef USE_ASSERT_CHECKING
			int			start = out->len;
#endif

			appendStringInfoString(out, ",\"changes\":[");
			foreach(lc, data->rel_order)
			{
				RelEntry   *re = lfirst(lc);

				if (re->is_c)
				{
					if (!first_group)
						appendStringInfoChar(out, ',');
					appendStringInfoString(out, re->prefix);
					appendStringInfoString(out, ",\"op\":\"c\"}");
					first_group = false;
					continue;
				}
				for (int op = 0; op < NUM_KEY_OPS; op++)
				{
					if (re->keys[op] == NIL)
						continue;
					if (!first_group)
						appendStringInfoChar(out, ',');
					appendStringInfoString(out, re->prefix);
					appendStringInfo(out, ",\"op\":\"%c\",\"k\":[", op_names[op]);
					append_keys(out, re->keys[op]);
					appendStringInfoString(out, "]}");
					first_group = false;
				}
			}
			appendStringInfoString(out, "]}");
			/* the budget is an upper bound of the message's length */
			Assert(out->len - start <= data->size);
		}

		OutputPluginWrite(ctx, true);
	}

	reset_txn_state(data);
	data->all = false;

	if (data->guc_nestlevel > 0)
	{
		AtEOXact_GUC(true, data->guc_nestlevel);
		data->guc_nestlevel = 0;
	}
}
