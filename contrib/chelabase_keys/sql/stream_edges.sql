\set ECHO none
\set VERBOSITY terse
\pset tuples_only on
\pset format unaligned
SET client_min_messages = warning;
-- W9 edges of streamed transactions (every transaction here is streamed, as in
-- stream.sql)
SET logical_decoding_work_mem = '64kB';
SET debug_logical_replication_streaming = immediate;
CREATE OR REPLACE FUNCTION skeys(slot text, VARIADIC opts text[] DEFAULT '{}') RETURNS SETOF text LANGUAGE sql AS $$
  SELECT regexp_replace(regexp_replace(data,
           '"lsn":"[0-9A-F]+/[0-9A-F]+","xid":[0-9]+', '"lsn":"L","xid":X'),
         '"rel":[0-9]+', '"rel":R', 'g')
  FROM pg_logical_slot_get_changes(slot, NULL, NULL, VARIADIC opts) $$;
SELECT 'created' FROM pg_create_logical_replication_slot('se', 'chelabase_keys');
CREATE TABLE se_a (id int PRIMARY KEY);
CREATE TABLE se_b (id int PRIMARY KEY);
CREATE TABLE se_c (id int PRIMARY KEY);
CREATE TABLE se_nopk (v int);
SELECT 'drained' FROM (SELECT count(*) FROM pg_logical_slot_get_changes('se', NULL, NULL)) d;
-- nested subtransactions rolled back.  Decoded after the rollback (as the SQL
-- functions do), an aborted subtransaction's changes never reach the plugin:
-- their catalog lookups fail as a concurrent abort and Postgres drops them, so
-- only the committed relation is listed.  (When the walsender streams a
-- subtransaction's change while it runs, the plugin keeps that relation after
-- the rollback: test_chelabase_keys_stream.py.)
BEGIN;
SAVEPOINT p1;
INSERT INTO se_b VALUES (1);
SAVEPOINT p2;
INSERT INTO se_c VALUES (1);
ROLLBACK TO p1;
INSERT INTO se_a VALUES (1);
SAVEPOINT p3;
INSERT INTO se_a VALUES (2);
RELEASE p3;
COMMIT;
SELECT * FROM skeys('se');
-- subtransactions aborted, then the top level: nothing, and the next one is clean
BEGIN;
INSERT INTO se_a VALUES (3);
SAVEPOINT p1;
INSERT INTO se_b VALUES (3);
ROLLBACK TO p1;
SAVEPOINT p2;
INSERT INTO se_c VALUES (3);
ROLLBACK;
INSERT INTO se_c VALUES (4);
SELECT * FROM skeys('se');
-- a table without a primary key is c, as any other
BEGIN;
INSERT INTO se_nopk VALUES (1), (2);
UPDATE se_nopk SET v = 3 WHERE v = 1;
DELETE FROM se_nopk WHERE v = 2;
INSERT INTO se_a VALUES (5);
COMMIT;
SELECT * FROM skeys('se');
-- a TRUNCATE as the transaction's first change, of several tables at once,
-- and of a table already listed: each relation once, in first-change order
BEGIN;
TRUNCATE se_c, se_b;
INSERT INTO se_a VALUES (6);
TRUNCATE se_a;
COMMIT;
SELECT * FROM skeys('se');
-- TRUNCATE past max_tables: all
BEGIN;
INSERT INTO se_a VALUES (7);
TRUNCATE se_b, se_c;
COMMIT;
SELECT * FROM skeys('se', 'max_tables', '2');
-- a speculative insert (ON CONFLICT) and a transactional logical message: c
-- for the table, the message skipped
BEGIN;
INSERT INTO se_a VALUES (8) ON CONFLICT (id) DO UPDATE SET id = 9;
INSERT INTO se_a VALUES (8) ON CONFLICT (id) DO UPDATE SET id = 9;
SELECT 'emitted' FROM pg_logical_emit_message(true, 'p', 'x');
COMMIT;
SELECT * FROM skeys('se');
-- a streamed transaction whose only row change was in a subtransaction rolled
-- back before the decoding: no change reaches the plugin, nothing is written
BEGIN;
CREATE TABLE se_e (id int PRIMARY KEY);
SAVEPOINT p1;
INSERT INTO se_b VALUES (10);
ROLLBACK TO p1;
COMMIT;
SELECT * FROM skeys('se');
-- max_message_bytes bounds a streamed message too: long escaped names, 200
-- relations fit 65536 bytes, 300 make the transaction "all" (max_tables 1000)
DO $$ BEGIN EXECUTE format('CREATE SCHEMA %I', repeat('"', 63)); END $$;
DO $$
BEGIN
  FOR i IN 1..300 LOOP
    EXECUTE format('CREATE TABLE %I.%I (id int)', repeat('"', 63), repeat('"', 55) || i);
  END LOOP;
END $$;
SELECT 'drained' FROM (SELECT count(*) FROM pg_logical_slot_get_changes('se', NULL, NULL)) d;
DO $$
BEGIN
  FOR i IN 1..200 LOOP
    EXECUTE format('INSERT INTO %I.%I VALUES (1)', repeat('"', 63), repeat('"', 55) || i);
  END LOOP;
END $$;
SELECT coalesce(data::json->>'all', json_array_length(data::json->'changes') || ' relations'),
       length(data) < 65536,
       (SELECT bool_and(c->>'op' = 'c' AND c->>'s' = repeat('"', 63))
          FROM json_array_elements(data::json->'changes') c)
  FROM pg_logical_slot_get_changes('se', NULL, NULL, 'max_tables', '1000', 'max_message_bytes', '65536');
DO $$
BEGIN
  FOR i IN 1..300 LOOP
    EXECUTE format('INSERT INTO %I.%I VALUES (2)', repeat('"', 63), repeat('"', 55) || i);
  END LOOP;
END $$;
SELECT * FROM skeys('se', 'max_tables', '1000', 'max_message_bytes', '65536');
DO $$ BEGIN EXECUTE format('DROP SCHEMA %I CASCADE', repeat('"', 63)); END $$;
-- the slot streamed
SELECT stream_txns > 0 FROM pg_stat_replication_slots WHERE slot_name = 'se';
SELECT 'dropped' FROM (SELECT pg_drop_replication_slot('se')) d;
\set ECHO none
