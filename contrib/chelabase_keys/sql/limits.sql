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
SELECT 'created' FROM pg_create_logical_replication_slot('l', 'chelabase_keys');
SELECT * FROM keys('l', 'nope', '1');
SELECT * FROM keys('l', 'max_tables', 'x');
SELECT * FROM keys('l', 'max_tables', '0');
SELECT * FROM keys('l', 'max_tables', '1001');
SELECT * FROM keys('l', 'max_keys_per_table', '0');
SELECT * FROM keys('l', 'max_keys_per_table', '10001');
SELECT * FROM keys('l', 'max_message_bytes', '65535');
SELECT * FROM keys('l', 'max_message_bytes', '16777217');
CREATE TABLE lk (id int PRIMARY KEY);
INSERT INTO lk SELECT generate_series(1, 2);
SELECT * FROM keys('l', 'max_keys_per_table', '2');
INSERT INTO lk SELECT generate_series(3, 5);
SELECT * FROM keys('l', 'max_keys_per_table', '2');
CREATE TABLE la (id int PRIMARY KEY);
CREATE TABLE lb (id int PRIMARY KEY);
CREATE TABLE lc (id int PRIMARY KEY);
BEGIN;
INSERT INTO la VALUES (1);
INSERT INTO lb VALUES (1);
INSERT INTO lc VALUES (1);
COMMIT;
SELECT * FROM keys('l', 'max_tables', '2');
BEGIN;
INSERT INTO la VALUES (2);
INSERT INTO lb VALUES (2);
COMMIT;
SELECT * FROM keys('l', 'max_tables', '2');
CREATE TABLE lt (id text PRIMARY KEY);
INSERT INTO lt SELECT repeat(chr(97 + i % 26), 1000) || i FROM generate_series(1, 100) i;
SELECT * FROM keys('l', 'max_message_bytes', '65536');
SELECT 'dropped' FROM (SELECT pg_drop_replication_slot('l')) d;
