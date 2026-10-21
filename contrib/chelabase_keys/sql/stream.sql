\set ECHO none
\set VERBOSITY terse
\pset tuples_only on
\pset format unaligned
SET client_min_messages = warning;
-- W9: the plugin streams transactions that go past logical_decoding_work_mem.
-- "immediate" streams every change as soon as it is decoded (the session runs
-- the decoding of pg_logical_slot_*_changes), so every transaction below is
-- streamed; a streamed transaction reports each relation it touched as "c", in
-- first-change order, in one message at its commit.
SET logical_decoding_work_mem = '64kB';
SET debug_logical_replication_streaming = immediate;
CREATE OR REPLACE FUNCTION keys(slot text, VARIADIC opts text[] DEFAULT '{}') RETURNS SETOF text LANGUAGE sql AS $$
  SELECT regexp_replace(regexp_replace(data,
           '"lsn":"[0-9A-F]+/[0-9A-F]+","xid":[0-9]+', '"lsn":"L","xid":X'),
         '"rel":[0-9]+', '"rel":R', 'g')
  FROM pg_logical_slot_get_changes(slot, NULL, NULL, VARIADIC opts) $$;
SELECT 'created' FROM pg_create_logical_replication_slot('s', 'chelabase_keys');
CREATE TABLE st_a (id int PRIMARY KEY);
CREATE TABLE st_b (id int PRIMARY KEY);
CREATE TABLE st_c (id int PRIMARY KEY);
SELECT 'drained' FROM (SELECT count(*) FROM pg_logical_slot_get_changes('s', NULL, NULL)) d;
-- one streamed transaction over two tables: one message, two c entries in
-- first-change order (st_b first), whatever the number of changes
BEGIN;
INSERT INTO st_b VALUES (1);
INSERT INTO st_a VALUES (1), (2);
INSERT INTO st_b VALUES (2);
UPDATE st_a SET id = 3 WHERE id = 2;
DELETE FROM st_b WHERE id = 1;
COMMIT;
SELECT * FROM keys('s');
-- a subtransaction rolled back: the message has only st_a.  Here the decoding
-- runs after the rollback, so while Postgres streams the subtransaction's
-- change its catalog lookup finds the subtransaction aborted ("concurrent
-- abort", genam.c HandleConcurrentAbort, caught in ReorderBufferProcessTXN)
-- and the change never reaches the plugin.  A subtransaction streamed while it
-- still ran keeps its relation after the rollback (the plugin keeps the entry;
-- an extra c is a harmless refetch): test_chelabase_keys_stream.py covers that
-- over the walsender.
BEGIN;
INSERT INTO st_a VALUES (4);
SAVEPOINT p;
INSERT INTO st_b VALUES (4);
ROLLBACK TO p;
INSERT INTO st_a VALUES (5);
COMMIT;
SELECT * FROM keys('s');
-- a top-level rollback writes nothing, and the next transaction starts clean
BEGIN;
INSERT INTO st_a VALUES (6);
INSERT INTO st_b VALUES (6);
ROLLBACK;
INSERT INTO st_c VALUES (6);
SELECT * FROM keys('s');
-- PREPARE TRANSACTION: nothing at the prepare (peek, so the slot doesn't move);
-- the message comes at COMMIT PREPARED, with the transaction's full xid and
-- the COMMIT PREPARED record's end as its lsn
BEGIN;
INSERT INTO st_a VALUES (7);
INSERT INTO st_b VALUES (7);
SELECT pg_current_xact_id() AS x \gset
PREPARE TRANSACTION 'st_p1';
SELECT count(*) FROM pg_logical_slot_peek_changes('s', NULL, NULL);
SELECT pg_current_wal_insert_lsn() AS before_commit \gset
COMMIT PREPARED 'st_p1';
SELECT regexp_replace(regexp_replace(data,
         '"lsn":"[0-9A-F]+/[0-9A-F]+","xid":[0-9]+', '"lsn":"L","xid":X'),
       '"rel":[0-9]+', '"rel":R', 'g'),
       (data::json->>'xid')::xid8 = :'x'::xid8,
       (data::json->>'lsn')::pg_lsn = lsn,
       lsn > :'before_commit'::pg_lsn
  FROM pg_logical_slot_get_changes('s', NULL, NULL);
-- ROLLBACK PREPARED of a streamed transaction writes nothing
BEGIN;
INSERT INTO st_a VALUES (8);
INSERT INTO st_c VALUES (8);
PREPARE TRANSACTION 'st_p2';
ROLLBACK PREPARED 'st_p2';
INSERT INTO st_b VALUES (8);
SELECT * FROM keys('s');
-- TRUNCATE inside a streamed transaction is c for the truncated relation, beside
-- the transaction's other relations
BEGIN;
INSERT INTO st_a VALUES (9);
TRUNCATE st_c;
COMMIT;
SELECT * FROM keys('s');
-- max_tables: two relations fit max_tables 2 (c each); a third makes it "all"
BEGIN;
INSERT INTO st_a VALUES (10);
INSERT INTO st_b VALUES (10);
COMMIT;
SELECT * FROM keys('s', 'max_tables', '2');
BEGIN;
INSERT INTO st_a VALUES (11);
INSERT INTO st_b VALUES (11);
INSERT INTO st_c VALUES (11);
COMMIT;
SELECT * FROM keys('s', 'max_tables', '2');
-- a transaction with only DDL writes nothing
BEGIN;
CREATE TABLE st_e (id int PRIMARY KEY);
ALTER TABLE st_e ADD COLUMN v int;
COMMIT;
SELECT * FROM keys('s');
-- a relation dropped later in the same transaction keeps the name its change
-- was decoded with (the historic catalog)
CREATE TABLE st_d (id int PRIMARY KEY);
SELECT 'drained' FROM (SELECT count(*) FROM pg_logical_slot_get_changes('s', NULL, NULL)) d;
BEGIN;
INSERT INTO st_d VALUES (1);
DROP TABLE st_d;
INSERT INTO st_a VALUES (12);
COMMIT;
SELECT * FROM keys('s');
-- a change whose only new data is out of line (an update of a TOASTed column):
-- the TOAST chunks are reassembled before the change reaches the plugin, which
-- sees one change of the table (c), never the TOAST table
CREATE TABLE st_t (id int PRIMARY KEY, big text);
ALTER TABLE st_t ALTER COLUMN big SET STORAGE EXTERNAL;
INSERT INTO st_t VALUES (1, repeat('x', 3000));
SELECT 'drained' FROM (SELECT count(*) FROM pg_logical_slot_get_changes('s', NULL, NULL)) d;
UPDATE st_t SET big = repeat('y', 5000);
SELECT * FROM keys('s');
-- xid is the full transaction id; lsn is the message's position
BEGIN;
INSERT INTO st_a VALUES (13);
SELECT pg_current_xact_id() AS x \gset
COMMIT;
SELECT (data::json->>'xid')::xid8 = :'x'::xid8, (data::json->>'lsn')::pg_lsn = lsn
  FROM pg_logical_slot_get_changes('s', NULL, NULL);
-- the slot streamed (it didn't decode every transaction at its commit)
SELECT stream_txns > 0 FROM pg_stat_replication_slots WHERE slot_name = 's';
SELECT 'dropped' FROM (SELECT pg_drop_replication_slot('s')) d;
