# W9: two large transactions streamed while small ones commit between their
# changes.  Each large transaction goes past logical_decoding_work_mem (64kB)
# and is streamed; the small ones stay under it and are decoded at their
# commit, with keys.  Every transaction writes one message, in commit order.

setup
{
  SELECT 'init' FROM pg_create_logical_replication_slot('iso', 'chelabase_keys');
  CREATE TABLE si_a (id int PRIMARY KEY, pad text);
  CREATE TABLE si_b (id int PRIMARY KEY);
  CREATE TABLE si_c (id int PRIMARY KEY, pad text);
  CREATE TABLE si_d (id int PRIMARY KEY, pad text);
  -- 1792 bytes that don't compress; a row stays under the TOAST threshold, so
  -- each change can be streamed as soon as it is decoded
  CREATE FUNCTION si_pad(n int) RETURNS text LANGUAGE sql IMMUTABLE AS
    $$ SELECT string_agg(md5(n::text || ':' || i), '') FROM generate_series(1, 56) i $$;
  -- one line per message: each relation's table, op and keys (or their count),
  -- dot-padded to the column name's width (36), so the aligned output the
  -- isolation tester prints has no trailing blanks
  CREATE FUNCTION si_msgs() RETURNS SETOF text LANGUAGE sql AS $$
    SELECT rpad(CASE WHEN data::json->>'all' IS NOT NULL THEN 'all'
      ELSE (SELECT string_agg((c->>'t') || ' ' || (c->>'op') ||
              coalesce(' ' || CASE WHEN json_array_length(c->'k') <= 3
                                   THEN (c->'k')::text
                                   ELSE json_array_length(c->'k') || ' keys' END, ''),
              ', ' ORDER BY o)
            FROM json_array_elements(data::json->'changes') WITH ORDINALITY AS e(c, o))
      END, 36, '.')
    FROM pg_logical_slot_get_changes('iso', NULL, NULL) $$;
}

teardown
{
  DROP TABLE si_a, si_b, si_c, si_d;
  DROP FUNCTION si_pad(int), si_msgs();
  DO $$ BEGIN PERFORM pg_drop_replication_slot('iso'); END $$;
}

session "s1"
setup { SET synchronous_commit = on; }
step "s1_begin" { BEGIN; }
step "s1_a" { INSERT INTO si_a SELECT g, si_pad(g) FROM generate_series(1, 60) g; }
step "s1_c" { INSERT INTO si_c SELECT g, si_pad(g) FROM generate_series(1, 60) g; }
step "s1_commit" { COMMIT; }

session "s2"
setup { SET synchronous_commit = on; }
step "s2_b1" { INSERT INTO si_b VALUES (1); }
step "s2_b2" { INSERT INTO si_b VALUES (2); }
step "s2_b3" { INSERT INTO si_b VALUES (3); }

session "s3"
setup { SET synchronous_commit = on; }
step "s3_begin" { BEGIN; }
step "s3_d" { INSERT INTO si_d SELECT g, si_pad(g) FROM generate_series(1, 60) g; }
step "s3_commit" { COMMIT; }

session "s0"
setup { SET logical_decoding_work_mem = '64kB'; }
step "s0_get" { SELECT m AS one_line_per_message_in_commit_order FROM si_msgs() m; }

# s1 starts first and commits after s3; small transactions commit between
# their changes
permutation "s1_begin" "s1_a" "s3_begin" "s3_d" "s2_b1" "s1_c" "s2_b2" "s3_commit" "s1_commit" "s2_b3" "s0_get"
