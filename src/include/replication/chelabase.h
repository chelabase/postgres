/*-------------------------------------------------------------------------
 *
 * chelabase.h
 *	  Names Chelabase's realtime path relies on, the session's
 *	  chelabase_realtime flag, and the server's walproposer flag.
 *
 * The role named CHELABASE_REALTIME_ROLE may only open logical replication
 * connections, set no parameter in its startup packet but client_encoding
 * and application_name (postinit.c), run IDENTIFY_SYSTEM, create one
 * temporary chelabase_keys slot whose name starts with
 * CHELABASE_REALTIME_SLOT_PREFIX, and stream from that slot (walsender.c).
 * Slot names with that prefix are reserved for the role (slot.c).
 * Hot-standby feedback is ignored on every logical slot (walsender.c).
 *
 * src/include/replication/chelabase.h
 *
 *-------------------------------------------------------------------------
 */
#ifndef CHELABASE_H
#define CHELABASE_H

#define CHELABASE_REALTIME_ROLE "chelabase_realtime"
#define CHELABASE_KEYS_PLUGIN "chelabase_keys"
#define CHELABASE_REALTIME_SLOT_PREFIX "rt_"

/*
 * True when this session's authenticated user is CHELABASE_REALTIME_ROLE.
 * Set once by InitPostgres (postinit.c), never changed afterwards.
 */
extern PGDLLIMPORT bool am_chelabase_realtime;

/*
 * True when the neon walproposer runs in this server: set by the neon
 * extension in the postmaster (shared_preload_libraries) where it registers
 * the walproposer background worker, so every child inherits it.  Default
 * false, no GUC.  While it is set, only the walproposer can be a
 * synchronous standby (syncrep.c, U7b).
 */
extern PGDLLIMPORT bool chelabase_walproposer_active;

#endif							/* CHELABASE_H */
