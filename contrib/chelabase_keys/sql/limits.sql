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
-- T2 m1: strict integers (no sign, no leading or trailing space) and each option once
SELECT * FROM keys('l', 'max_tables', ' 5');
SELECT * FROM keys('l', 'max_tables', E'\t5');
SELECT * FROM keys('l', 'max_tables', '+5');
SELECT * FROM keys('l', 'max_tables', '5 ');
SELECT * FROM keys('l', 'max_tables', '5', 'max_tables', '5');
SELECT * FROM keys('l', 'max_keys_per_table', '5', 'max_tables', '5', 'max_keys_per_table', '6');
SELECT * FROM keys('l', 'max_message_bytes', '65536', 'max_message_bytes', '65536');
SELECT * FROM keys('l', 'max_tables', '5', 'max_keys_per_table', '6', 'max_message_bytes', '65536');
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
-- T2 m2: the budget bounds memory, not only text: each key costs at least its
-- hash entry (32 bytes) besides its text, so 2000 small keys (about 20 kB of
-- text) don't fit max_message_bytes 65536 ...
CREATE TABLE lm (id int PRIMARY KEY);
INSERT INTO lm SELECT generate_series(10000, 11999);
SELECT coalesce(data::json->>'all', 'keys ' || json_array_length(data::json->'changes'->0->'k'))
  FROM pg_logical_slot_get_changes('l', NULL, NULL,
         'max_keys_per_table', '10000', 'max_message_bytes', '65536');
-- ... and still fit the default budget
INSERT INTO lm SELECT generate_series(20000, 21999);
SELECT coalesce(data::json->>'all', 'keys ' || json_array_length(data::json->'changes'->0->'k'))
  FROM pg_logical_slot_get_changes('l', NULL, NULL, 'max_keys_per_table', '10000');
-- the budget at the limit and one byte over: one long key per transaction, its
-- length stepping up by one byte; a message is never longer than the limit, the
-- messages switch from keys to "all" once and for good, and the longest message
-- with keys comes within 512 bytes of the limit (the budget is an upper bound,
-- not a loose one)
CREATE TABLE lx (id text PRIMARY KEY);
DO $$
BEGIN
  FOR n IN 64900..65536 LOOP
    INSERT INTO lx VALUES (repeat('y', n));
    COMMIT;
  END LOOP;
END $$;
WITH m AS (
  SELECT i, octet_length(data) AS len, data::json->>'all' IS NOT NULL AS is_all
  FROM pg_logical_slot_get_changes('l', NULL, NULL, 'max_message_bytes', '65536')
       WITH ORDINALITY AS c(lsn, xid, data, i))
SELECT count(*) AS messages,
       bool_and(len <= 65536) AS within,
       count(*) FILTER (WHERE NOT is_all) > 0 AND count(*) FILTER (WHERE is_all) > 0 AS both,
       NOT EXISTS (SELECT FROM m a JOIN m k ON k.i > a.i WHERE a.is_all AND NOT k.is_all) AS once,
       max(len) FILTER (WHERE NOT is_all) >= 65536 - 512 AS tight
  FROM m;
SELECT 'dropped' FROM (SELECT pg_drop_replication_slot('l')) d;
