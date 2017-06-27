SELECT * FROM pglogical_regress_variables()
\gset

\c :provider_dsn

SELECT * FROM pglogical.create_replication_set('delay');

\c :subscriber_dsn

CREATE or REPLACE function int2interval (x integer) returns interval as
$$ select $1*'1 sec'::interval $$
language sql;

SELECT * FROM pglogical.create_subscription(
    subscription_name := 'test_subscription_delay',
    provider_dsn := (SELECT provider_dsn FROM pglogical_regress_variables()) || ' user=super',
	replication_sets := '{delay}',
	forward_origins := '{}',
	synchronize_structure := false,
	synchronize_data := false,
	apply_delay := int2interval(1) -- 1 second
);

DO $$
BEGIN
    FOR i IN 1..300 LOOP
        IF NOT EXISTS (SELECT 1 FROM pglogical.local_sync_status WHERE sync_status != 'r') THEN
            EXIT;
        END IF;
        PERFORM pg_sleep(0.1);
    END LOOP;
END;$$;

SELECT sync_kind, sync_subid, sync_nspname, sync_relname, sync_status FROM pglogical.local_sync_status ORDER BY 2,3,4;

SELECT * FROM pglogical.show_subscription_status();

-- Make sure we see the slot and active connection
\c :provider_dsn
SELECT plugin, slot_type, database, active FROM pg_replication_slots;
SELECT count(*) FROM pg_stat_replication;

CREATE TABLE public.timestamps (
        id text primary key,
        ts timestamptz
);

SELECT pglogical.replicate_ddl_command($$
    CREATE TABLE public.basic_dml1 (
        id serial primary key,
        other integer,
        data text,
        something interval
    );
$$);
-- clear old applies, from any previous tests etc.
SELECT pglogical_wait_slot_confirm_lsn(NULL, NULL);

INSERT INTO timestamps VALUES ('ts1', CURRENT_TIMESTAMP);

SELECT * FROM pglogical.replication_set_add_table('delay', 'basic_dml1');

SELECT pglogical_wait_slot_confirm_lsn(NULL, NULL);

INSERT INTO timestamps VALUES ('ts2', CURRENT_TIMESTAMP);

INSERT INTO basic_dml1(other, data, something)
VALUES (5, 'foo', '1 minute'::interval),
       (4, 'bar', '12 weeks'::interval),
       (3, 'baz', '2 years 1 hour'::interval),
       (2, 'qux', '8 months 2 days'::interval),
       (1, NULL, NULL);

SELECT pglogical_wait_slot_confirm_lsn(NULL, NULL);

INSERT INTO timestamps VALUES ('ts3', CURRENT_TIMESTAMP);

SELECT EXTRACT(EPOCH FROM (SELECT ts from timestamps where id = 'ts2')) -
       EXTRACT(EPOCH FROM (SELECT ts from timestamps where id = 'ts1'))
       BETWEEN 1 AND 2.5 AS ddl_replicate_time_ok;

SELECT EXTRACT(EPOCH FROM (SELECT ts from timestamps where id = 'ts3')) -
       EXTRACT(EPOCH FROM (SELECT ts from timestamps where id = 'ts2'))
       BETWEEN 1 AND 2.5 AS inserts_replicate_time_ok;

\c :subscriber_dsn

SELECT * FROM basic_dml1;

SELECT pglogical.drop_subscription('test_subscription_delay');

\c :provider_dsn
\set VERBOSITY terse
SELECT * FROM pglogical.drop_replication_set('delay');
DROP TABLE public.timestamps CASCADE;
SELECT pglogical.replicate_ddl_command($$
    DROP TABLE public.basic_dml1 CASCADE;
$$);
