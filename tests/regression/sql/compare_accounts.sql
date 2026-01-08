SET ROLE reptracker_owner;

CREATE OR REPLACE FUNCTION reptracker_account_dump.compare_accounts()
RETURNS void
LANGUAGE 'plpgsql'
VOLATILE
AS
$$
BEGIN
RAISE NOTICE 'Comparing reputation tracker with account_dump...';
WITH account_reputation AS MATERIALIZED (
  SELECT 
    account_id,
    reputation
  FROM reptracker_account_dump.account_reputation
),
current_account_reputation AS MATERIALIZED (
  SELECT account_id, reputation 
  FROM account_reputations 
),
selected AS MATERIALIZED (
SELECT
account_reputation.account_id,
account_reputation.reputation,
car.reputation AS current_reputation
FROM account_reputation
LEFT JOIN current_account_reputation car ON car.account_id = account_reputation.account_id
)
INSERT INTO reptracker_account_dump.differing_accounts
SELECT account_id FROM selected
WHERE reputation != current_reputation;
END
$$;

CREATE OR REPLACE FUNCTION reptracker_account_dump.compare_differing_account(_account_id int)
RETURNS SETOF reptracker_account_dump.account_type -- noqa: LT01
LANGUAGE 'plpgsql' STABLE
AS
$$
BEGIN
  RETURN QUERY SELECT 
    account_id,
    reputation

  FROM reptracker_account_dump.account_reputation WHERE account_id = _account_id
  UNION ALL
  SELECT * FROM reptracker_account_dump.get_account_setof(_account_id);

END
$$;


RESET ROLE;
