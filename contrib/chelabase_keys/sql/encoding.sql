\set ECHO none
\set VERBOSITY terse
\pset tuples_only on
\pset format unaligned
SET client_min_messages = warning;
-- U4: every string chelabase_keys emits (keys, schema and table names) is UTF-8,
-- whatever the database encoding; a SQL_ASCII database (no encoding to convert
-- from) is refused when the plugin starts.  The messages are read as bytes
-- (pg_logical_slot_get_binary_changes) and printed with encode(..., 'escape'),
-- so every non-ASCII byte shows as an octal escape: UTF-8's two- or three-byte
-- sequences against LATIN1's or EUC_JP's own bytes.  The client encoding is
-- UTF8 (pg_regress --encoding), so this file's names arrive converted.
SELECT current_database() AS home \gset
CREATE DATABASE ck_latin1 TEMPLATE template0 ENCODING 'LATIN1' LC_COLLATE 'C' LC_CTYPE 'C';
CREATE DATABASE ck_euc_jp TEMPLATE template0 ENCODING 'EUC_JP' LC_COLLATE 'C' LC_CTYPE 'C';
CREATE DATABASE ck_sql_ascii TEMPLATE template0 ENCODING 'SQL_ASCII' LC_COLLATE 'C' LC_CTYPE 'C';
-- a UTF-8 database: the strings go out as they are
CREATE FUNCTION raw_keys(slot text) RETURNS SETOF text LANGUAGE sql AS $$
  SELECT regexp_replace(regexp_replace(encode(data, 'escape'),
           '"lsn":"[0-9A-F]+/[0-9A-F]+","xid":[0-9]+', '"lsn":"L","xid":X'),
         '"rel":[0-9]+', '"rel":R', 'g')
  FROM pg_logical_slot_get_binary_changes(slot, NULL, NULL) $$;
SELECT 'created' FROM pg_create_logical_replication_slot('e0', 'chelabase_keys');
CREATE SCHEMA "sché";
CREATE TABLE "sché"."tâb" (id text PRIMARY KEY);
INSERT INTO "sché"."tâb" VALUES ('café');
SELECT * FROM raw_keys('e0');
SELECT 'dropped' FROM (SELECT pg_drop_replication_slot('e0')) d;
-- LATIN1: é and â are one byte each in the database, two in the message
\c ck_latin1
SET client_min_messages = warning;
CREATE FUNCTION raw_keys(slot text) RETURNS SETOF text LANGUAGE sql AS $$
  SELECT regexp_replace(regexp_replace(encode(data, 'escape'),
           '"lsn":"[0-9A-F]+/[0-9A-F]+","xid":[0-9]+', '"lsn":"L","xid":X'),
         '"rel":[0-9]+', '"rel":R', 'g')
  FROM pg_logical_slot_get_binary_changes(slot, NULL, NULL) $$;
SELECT 'created' FROM pg_create_logical_replication_slot('e1', 'chelabase_keys');
CREATE SCHEMA "sché";
CREATE TABLE "sché"."tâb" (id text PRIMARY KEY, n int);
INSERT INTO "sché"."tâb" VALUES ('café', 0);
UPDATE "sché"."tâb" SET n = 1;
UPDATE "sché"."tâb" SET id = 'caffè';
SELECT * FROM raw_keys('e1');
SELECT 'dropped' FROM (SELECT pg_drop_replication_slot('e1')) d;
-- EUC_JP (multi-byte): two bytes per character in the database, three in the message
\c ck_euc_jp
SET client_min_messages = warning;
CREATE FUNCTION raw_keys(slot text) RETURNS SETOF text LANGUAGE sql AS $$
  SELECT regexp_replace(regexp_replace(encode(data, 'escape'),
           '"lsn":"[0-9A-F]+/[0-9A-F]+","xid":[0-9]+', '"lsn":"L","xid":X'),
         '"rel":[0-9]+', '"rel":R', 'g')
  FROM pg_logical_slot_get_binary_changes(slot, NULL, NULL) $$;
SELECT 'created' FROM pg_create_logical_replication_slot('e2', 'chelabase_keys');
CREATE SCHEMA "スキ";
CREATE TABLE "スキ"."表" (a text, b text, PRIMARY KEY (a, b));
INSERT INTO "スキ"."表" VALUES ('日本', 'x');
SELECT * FROM raw_keys('e2');
SELECT 'dropped' FROM (SELECT pg_drop_replication_slot('e2')) d;
-- SQL_ASCII: refused at slot creation (the plugin's startup), temporary or not;
-- no slot is left behind
\c ck_sql_ascii
SET client_min_messages = warning;
SELECT 'created' FROM pg_create_logical_replication_slot('e3', 'chelabase_keys');
SELECT 'created' FROM pg_create_logical_replication_slot('e4', 'chelabase_keys', true);
SELECT count(*) FROM pg_replication_slots WHERE slot_name IN ('e3', 'e4');
SELECT count(*) FROM (SELECT pg_drop_replication_slot(slot_name) FROM pg_replication_slots
  WHERE slot_name IN ('e3', 'e4') AND NOT temporary) d;
\c :home
SET client_min_messages = warning;
DROP DATABASE ck_latin1 WITH (FORCE);
DROP DATABASE ck_euc_jp WITH (FORCE);
DROP DATABASE ck_sql_ascii WITH (FORCE);
