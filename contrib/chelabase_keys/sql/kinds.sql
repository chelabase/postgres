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
SELECT 'created' FROM pg_create_logical_replication_slot('kk', 'chelabase_keys');
SET IntervalStyle = 'postgres_verbose';
SET extra_float_digits = 0;
SET bytea_output = 'escape';
SET search_path = public, pg_catalog;
CREATE TYPE mood AS ENUM ('sad', 'happy');
CREATE TABLE target (id int);
CREATE TABLE k_big (id bigint PRIMARY KEY);
CREATE TABLE k_num (id numeric PRIMARY KEY);
CREATE TABLE k_txt (id text PRIMARY KEY);
CREATE TABLE k_uuid (id uuid PRIMARY KEY);
CREATE TABLE k_ts (id timestamptz PRIMARY KEY);
CREATE TABLE k_iv (id interval PRIMARY KEY);
CREATE TABLE k_fl (id float8 PRIMARY KEY);
CREATE TABLE k_by (id bytea PRIMARY KEY);
CREATE TABLE k_en (id mood PRIMARY KEY);
CREATE TABLE k_mo (id money PRIMARY KEY);
CREATE TABLE k_rc (id regclass PRIMARY KEY);
CREATE TABLE k_comp (b text, a int, note text, PRIMARY KEY (a, b));
INSERT INTO k_big VALUES (9007199254740993);
INSERT INTO k_num VALUES (1.50);
INSERT INTO k_txt VALUES (E'q"uo\\te é');
INSERT INTO k_uuid VALUES ('A0EEBC99-9C0B-4EF8-BB6D-6BB9BD380A11');
INSERT INTO k_ts VALUES ('2026-01-02 03:04:05+00');
INSERT INTO k_iv VALUES ('1 day 2 hours');
INSERT INTO k_fl VALUES (0.1);
INSERT INTO k_by VALUES ('\x0102');
INSERT INTO k_en VALUES ('happy');
INSERT INTO k_mo VALUES (12.34);
INSERT INTO k_rc VALUES ('target'::regclass);
INSERT INTO k_comp VALUES ('x', 1, 'n');
SELECT * FROM keys('kk');
SELECT 'dropped' FROM (SELECT pg_drop_replication_slot('kk')) d;
