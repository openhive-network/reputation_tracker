SET ROLE reptracker_owner;

DO $$
BEGIN

CREATE SCHEMA reptracker_backend AUTHORIZATION reptracker_owner;

CREATE TABLE IF NOT EXISTS reptracker_backend.account_reputation (
    account_id INT,
    reputation BIGINT DEFAULT 0,
 
CONSTRAINT pk_account_reputation_comparison PRIMARY KEY (account_id)
);

CREATE TABLE IF NOT EXISTS reptracker_backend.differing_accounts (
  account_id INT
);


EXCEPTION WHEN duplicate_schema THEN RAISE NOTICE '%, skipping', SQLERRM USING ERRCODE = SQLSTATE;

END
$$;

CREATE OR REPLACE FUNCTION reptracker_backend.dump_current_account_stats(account_data jsonb)
RETURNS void
LANGUAGE 'plpgsql'
VOLATILE
AS
$$
BEGIN
INSERT INTO reptracker_backend.account_reputation
SELECT
    (SELECT av.id FROM hive.accounts_view av WHERE av.name = (account_data->>'account'))::INT AS account_id,
    (account_data->>'reputation')::BIGINT AS reputation;
END
$$;

DROP TYPE IF EXISTS reptracker_backend.account_type CASCADE; -- noqa: LT01
CREATE TYPE reptracker_backend.account_type AS
(
    account_id INT,
    reputation BIGINT

);

CREATE OR REPLACE FUNCTION reptracker_backend.get_account_setof(_account_id int)
RETURNS reptracker_backend.account_type -- noqa: LT01
LANGUAGE 'plpgsql'
STABLE
AS
$$
BEGIN

RETURN (SELECT ROW(account_id, reputation)
FROM reptracker_app.account_reputations WHERE account_id = _account_id
);

END
$$;

RESET ROLE;
