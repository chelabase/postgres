# W9: many streamed transactions in progress at once.  Four large
# transactions are each streamed in several blocks interleaved with the
# others' and with small transactions decoded at their commit; two of the
# large ones end in a top-level rollback, one after a rolled-back
# subtransaction.  Every committed transaction writes one message, in commit
# order, with only its own relations; the rolled-back ones write nothing.
# (The decoding runs after every rollback, so Postgres drops the rolled-back
# subtransactions' changes to sm_x before they reach the plugin.)

setup
{
  SELECT 'init' FROM pg_create_logical_replication_slot('many', 'chelabase_keys');
  CREATE TABLE sm_1 (id int PRIMARY KEY, pad text);
  CREATE TABLE sm_2 (id int PRIMARY KEY, pad text);
  CREATE TABLE sm_3 (id int PRIMARY KEY, pad text);
  CREATE TABLE sm_4 (id int PRIMARY KEY, pad text);
  CREATE TABLE sm_x (id int PRIMARY KEY, pad text);
  CREATE TABLE sm_s (id int PRIMARY KEY);
  -- 1792 bytes that don't compress (as stream_interleave)
  CREATE FUNCTION sm_pad(n int) RETURNS text LANGUAGE sql IMMUTABLE AS
    $$ SELECT string_agg(md5(n::text || ':' || i), '') FROM generate_series(1, 56) i $$;
  CREATE FUNCTION sm_msgs() RETURNS SETOF text LANGUAGE sql AS $$
    SELECT rpad(CASE WHEN data::json->>'all' IS NOT NULL THEN 'all'
      ELSE (SELECT string_agg((c->>'t') || ' ' || (c->>'op') ||
              coalesce(' ' || CASE WHEN json_array_length(c->'k') <= 3
                                   THEN (c->'k')::text
                                   ELSE json_array_length(c->'k') || ' keys' END, ''),
              ', ' ORDER BY o)
            FROM json_array_elements(data::json->'changes') WITH ORDINALITY AS e(c, o))
      END, 36, '.')
    FROM pg_logical_slot_get_changes('many', NULL, NULL) $$;
}

teardown
{
  DROP TABLE sm_1, sm_2, sm_3, sm_4, sm_x, sm_s;
  DROP FUNCTION sm_pad(int), sm_msgs();
  DO $$ BEGIN PERFORM pg_drop_replication_slot('many'); END $$;
}

session "s1"
setup { SET synchronous_commit = on; }
step "s1_begin" { BEGIN; }
step "s1_a" { INSERT INTO sm_1 SELECT g, sm_pad(g) FROM generate_series(1, 60) g; }
step "s1_b" { INSERT INTO sm_1 SELECT g, sm_pad(g) FROM generate_series(61, 120) g; }
step "s1_commit" { COMMIT; }

session "s2"
setup { SET synchronous_commit = on; }
step "s2_begin" { BEGIN; }
step "s2_a" { INSERT INTO sm_2 SELECT g, sm_pad(g) FROM generate_series(1, 60) g; }
step "s2_b" { INSERT INTO sm_2 SELECT g, sm_pad(g) FROM generate_series(61, 120) g; }
step "s2_rollback" { ROLLBACK; }

session "s3"
setup { SET synchronous_commit = on; }
step "s3_begin" { BEGIN; }
step "s3_a" { INSERT INTO sm_3 SELECT g, sm_pad(g) FROM generate_series(1, 60) g; }
step "s3_sp" { SAVEPOINT p; }
step "s3_x" { INSERT INTO sm_x SELECT g, sm_pad(g) FROM generate_series(1, 60) g; }
step "s3_rollback_to" { ROLLBACK TO p; }
step "s3_b" { INSERT INTO sm_3 SELECT g, sm_pad(g) FROM generate_series(61, 120) g; }
step "s3_commit" { COMMIT; }

session "s4"
setup { SET synchronous_commit = on; }
step "s4_begin" { BEGIN; }
step "s4_a" { INSERT INTO sm_4 SELECT g, sm_pad(g) FROM generate_series(1, 60) g; }
step "s4_sp" { SAVEPOINT p; }
step "s4_x" { INSERT INTO sm_x SELECT g, sm_pad(g) FROM generate_series(1001, 1060) g; }
step "s4_rollback_to" { ROLLBACK TO p; }
step "s4_rollback" { ROLLBACK; }

session "s5"
setup { SET synchronous_commit = on; }
step "s5_1" { INSERT INTO sm_s VALUES (1); }
step "s5_2" { INSERT INTO sm_s VALUES (2); }
step "s5_3" { INSERT INTO sm_s VALUES (3); }

session "s0"
setup { SET logical_decoding_work_mem = '64kB'; }
step "s0_get" { SELECT m AS one_line_per_message_in_commit_order FROM sm_msgs() m; }

permutation "s1_begin" "s2_begin" "s3_begin" "s4_begin" "s1_a" "s2_a" "s3_a" "s4_a" "s5_1" "s3_sp" "s3_x" "s4_sp" "s4_x" "s3_rollback_to" "s4_rollback_to" "s2_b" "s5_2" "s1_b" "s3_b" "s4_rollback" "s3_commit" "s2_rollback" "s1_commit" "s5_3" "s0_get"
