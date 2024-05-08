SET ROLE reptracker_owner;

CREATE SCHEMA IF NOT EXISTS reptracker_endpoints AUTHORIZATION reptracker_owner;

CREATE OR REPLACE FUNCTION reptracker_endpoints.get_account_reputation(_account_id INT)
RETURNS INT -- noqa: LT01, CP05
LANGUAGE 'plpgsql' STABLE
AS
$$
DECLARE
    _rep BIGINT;
    _result INT;
BEGIN
PERFORM set_config('response.headers', '[{"Cache-Control": "public, max-age=2"}]', true);

SELECT ar.reputation INTO _rep
FROM account_reputations ar
WHERE ar.account_id = _account_id;

IF _rep = 0 OR _rep IS NULL THEN
    RETURN 0;
ELSE
    WITH log_account_rep AS MATERIALIZED
    (
        SELECT 
            LOG(10, ABS(_rep)) AS rep,
            (CASE WHEN _rep < 0 THEN -1 ELSE 1 END) AS is_neg 
    ),
    calculate_rep AS MATERIALIZED
    (
        SELECT GREATEST(lar.rep - 9, 0) * lar.is_neg AS rep
        FROM log_account_rep lar
    )
        SELECT ((cr.rep * 9) + 25)::INT INTO _result
        FROM calculate_rep cr;

    RETURN _result;

END IF;

END
$$;

RESET ROLE;
