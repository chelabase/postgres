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
SELECT 'created' FROM pg_create_logical_replication_slot('k', 'chelabase_keys');
-- basic: one message per transaction; ops grouped; a key once per (relation, op)
CREATE TABLE orders (id int PRIMARY KEY, note text);
BEGIN;
INSERT INTO orders VALUES (1, 'a'), (2, 'b');
UPDATE orders SET note = 'c' WHERE id = 1;
UPDATE orders SET note = 'd' WHERE id = 1;
DELETE FROM orders WHERE id = 2;
COMMIT;
INSERT INTO orders VALUES (3, 'e');
SELECT * FROM keys('k');
-- a PK update is d + i; setting the PK to its own value is u
CREATE TABLE pku (id int PRIMARY KEY, v int);
INSERT INTO pku VALUES (1, 0);
UPDATE pku SET id = 2 WHERE id = 1;
UPDATE pku SET id = 2, v = 1 WHERE id = 2;
SELECT * FROM keys('k');
-- an unchanged out-of-line PK in an update of another column: u with the full key
CREATE TABLE tk (id text PRIMARY KEY, v int);
ALTER TABLE tk ALTER COLUMN id SET STORAGE EXTERNAL;
INSERT INTO tk VALUES (repeat('x', 2500), 0);
UPDATE tk SET v = 1;
SELECT replace(k, repeat('x', 2500), 'x*2500') FROM keys('k') k;
-- TRUNCATE is c
CREATE TABLE tr (id int PRIMARY KEY);
INSERT INTO tr VALUES (1);
TRUNCATE tr;
SELECT * FROM keys('k');
-- replica identity: keys only for the PK
CREATE TABLE nopk (v int);
CREATE TABLE rfull (id int PRIMARY KEY);
ALTER TABLE rfull REPLICA IDENTITY FULL;
CREATE TABLE rnothing (id int PRIMARY KEY);
ALTER TABLE rnothing REPLICA IDENTITY NOTHING;
CREATE TABLE ridx (id int PRIMARY KEY, u int NOT NULL UNIQUE);
ALTER TABLE ridx REPLICA IDENTITY USING INDEX ridx_pkey;
CREATE TABLE ridx2 (id int PRIMARY KEY, u int NOT NULL UNIQUE);
ALTER TABLE ridx2 REPLICA IDENTITY USING INDEX ridx2_u_key;
INSERT INTO nopk VALUES (1);
INSERT INTO rfull VALUES (1);
INSERT INTO rnothing VALUES (1);
INSERT INTO ridx VALUES (1, 1);
INSERT INTO ridx2 VALUES (1, 1);
SELECT * FROM keys('k');
-- a partition's change carries the partition
CREATE TABLE pt (id int PRIMARY KEY) PARTITION BY RANGE (id);
CREATE TABLE pt1 PARTITION OF pt FOR VALUES FROM (0) TO (100);
INSERT INTO pt VALUES (5);
SELECT (data::json->'changes'->0->>'rel')::oid = 'pt1'::regclass, data::json->'changes'->0->>'t'
  FROM pg_logical_slot_get_changes('k', NULL, NULL);
-- nothing for DDL alone or a rollback; DDL beside rows shows only the rows
CREATE TABLE e1 (id int PRIMARY KEY);
BEGIN;
INSERT INTO e1 VALUES (1);
ROLLBACK;
BEGIN;
ALTER TABLE e1 ADD COLUMN v int;
INSERT INTO e1 VALUES (2, 0);
COMMIT;
SELECT * FROM keys('k');
-- a prepared transaction is decoded at COMMIT PREPARED
BEGIN;
INSERT INTO e1 VALUES (3, 0);
PREPARE TRANSACTION 'p1';
SELECT * FROM keys('k');
COMMIT PREPARED 'p1';
SELECT * FROM keys('k');
-- xid is the full transaction id; lsn is the message's position
CREATE TABLE xl (id int PRIMARY KEY);
SELECT 'drained' FROM (SELECT count(*) FROM pg_logical_slot_get_changes('k', NULL, NULL)) d;
BEGIN;
INSERT INTO xl VALUES (1);
SELECT pg_current_xact_id() AS x \gset
COMMIT;
SELECT (data::json->>'xid')::xid8 = :'x'::xid8, (data::json->>'lsn')::pg_lsn = lsn
  FROM pg_logical_slot_get_changes('k', NULL, NULL);
SELECT 'dropped' FROM (SELECT pg_drop_replication_slot('k')) d;
