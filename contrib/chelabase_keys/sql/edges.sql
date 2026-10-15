\set ECHO none
\set VERBOSITY terse
\pset tuples_only on
\pset format unaligned
SET client_min_messages = warning;
CREATE OR REPLACE FUNCTION keys(slot text, VARIADIC opts text[] DEFAULT '{}') RETURNS SETOF text LANGUAGE sql AS $$
  SELECT regexp_replace(regexp_replace(data,
           '"lsn":"[0-9A-F]+/[0-9A-F]+","xid":[0-9]+', '"lsn":"L","xid":X'),
         '"rel":[0-9]+', '"rel":R', 'g')
  FROM pg_logical_slot_get_changes(slot, NULL, NULL, VARIADIC opts) $$;
SELECT 'created' FROM pg_create_logical_replication_slot('g', 'chelabase_keys');
-- T2 I1: in a composite PK, an unchanged out-of-line column doesn't hide a
-- change to another key column: the new key takes the unchanged column from
-- the old key Postgres logs, so the update is d (old key) + i (new key)
CREATE TABLE tc (a text, b int, v int, PRIMARY KEY (a, b));
ALTER TABLE tc ALTER COLUMN a SET STORAGE EXTERNAL;
INSERT INTO tc VALUES (repeat('x', 2500), 1, 0);
UPDATE tc SET b = b + 1;
SELECT replace(k, repeat('x', 2500), 'x*2500') FROM keys('g') k;
-- the same table: an update of a non-key column, or of b to its own value, is u
-- with the full key
UPDATE tc SET v = 1;
UPDATE tc SET b = b;
SELECT replace(k, repeat('x', 2500), 'x*2500') FROM keys('g') k;
-- a change to the out-of-line key column itself is d + i
UPDATE tc SET a = repeat('z', 2500);
SELECT replace(replace(k, repeat('x', 2500), 'x*2500'), repeat('z', 2500), 'z*2500') FROM keys('g') k;
-- a row inserted and its b changed in one transaction (the update's new tuple
-- points at the out-of-line value the insert stored): i for both keys, d for
-- the old one
BEGIN;
INSERT INTO tc VALUES (repeat('x', 2500), 7, 0);
UPDATE tc SET b = b + 10 WHERE b = 7;
COMMIT;
SELECT replace(replace(k, repeat('x', 2500), 'x*2500'), repeat('z', 2500), 'z*2500') FROM keys('g') k;
-- an update of an out-of-line non-key column only is u (the key is unchanged and
-- not logged)
CREATE TABLE tn (id int PRIMARY KEY, big text);
ALTER TABLE tn ALTER COLUMN big SET STORAGE EXTERNAL;
INSERT INTO tn VALUES (1, repeat('b', 3000));
UPDATE tn SET big = repeat('c', 3000);
UPDATE tn SET id = 2;
SELECT * FROM keys('g');
-- key-equal but text-different (numeric 1.0 -> 1.00) is d + i (RT3-9)
CREATE TABLE kn (id numeric PRIMARY KEY);
INSERT INTO kn VALUES (1.0);
UPDATE kn SET id = 1.00;
SELECT * FROM keys('g');
-- control characters, quotes and backslashes in a text key are JSON-escaped
CREATE TABLE kc (id text PRIMARY KEY);
INSERT INTO kc VALUES (E'a\x01b\nc\td\x1f"\\e');
SELECT (data::json->'changes'->0->'k'->0->>0) = E'a\x01b\nc\td\x1f"\\e'
  FROM pg_logical_slot_peek_changes('g', NULL, NULL);
SELECT * FROM keys('g');
-- arrays and composites in a PK, bytea
CREATE TYPE pair AS (x int, y text);
CREATE TABLE ka (id int[] PRIMARY KEY);
CREATE TABLE kr (id pair PRIMARY KEY);
CREATE TABLE kb (a bytea, b int, PRIMARY KEY (b, a));
INSERT INTO ka VALUES ('{1,2}');
INSERT INTO kr VALUES (ROW(1, 'a b'));
INSERT INTO kb VALUES ('\x00ff', 3);
SELECT * FROM keys('g');
-- schema and table names with quotes and dots, a 63-byte name
CREATE SCHEMA "we.ird""s";
CREATE TABLE "we.ird""s"."t.a""b" (id int PRIMARY KEY);
CREATE TABLE abcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabc (id int PRIMARY KEY);
INSERT INTO "we.ird""s"."t.a""b" VALUES (1);
INSERT INTO abcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabc VALUES (1);
SELECT * FROM keys('g');
-- TRUNCATE of two tables, and with CASCADE: c for each truncated table, in order
CREATE TABLE tx1 (id int PRIMARY KEY);
CREATE TABLE tx2 (id int PRIMARY KEY);
CREATE TABLE ta (id int PRIMARY KEY);
CREATE TABLE tf (id int PRIMARY KEY, a int REFERENCES ta);
INSERT INTO ta VALUES (1);
INSERT INTO tf VALUES (1, 1);
SELECT 'drained' FROM (SELECT count(*) FROM pg_logical_slot_get_changes('g', NULL, NULL)) d;
TRUNCATE tx1, tx2;
TRUNCATE ta CASCADE;
SELECT * FROM keys('g');
-- a transaction mixing TRUNCATE and DML: the truncated table is c, the rest keep keys
BEGIN;
INSERT INTO tx1 VALUES (5);
INSERT INTO tx2 VALUES (5);
TRUNCATE tx1;
INSERT INTO tx1 VALUES (6);
DELETE FROM tx2;
COMMIT;
SELECT * FROM keys('g');
-- a DEFERRABLE primary key is no replica identity: c
CREATE TABLE kd (id int PRIMARY KEY DEFERRABLE);
BEGIN;
INSERT INTO kd VALUES (1);
UPDATE kd SET id = 2;
DELETE FROM kd;
COMMIT;
SELECT * FROM keys('g');
SELECT 'dropped' FROM (SELECT pg_drop_replication_slot('g')) d;
