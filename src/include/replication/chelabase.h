/*-------------------------------------------------------------------------
 *
 * chelabase.h
 *	  Names Chelabase's realtime path relies on, and the session's
 *	  chelabase_realtime flag.
 *
 * The role named CHELABASE_REALTIME_ROLE may only open logical replication
 * connections, run IDENTIFY_SYSTEM, create one temporary chelabase_keys slot
 * whose name starts with CHELABASE_REALTIME_SLOT_PREFIX, and stream from that
 * slot (walsender.c, postinit.c).  Slot names with that prefix are reserved
 * for the role (slot.c).
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

#endif							/* CHELABASE_H */
