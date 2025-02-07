SET ROLE reptracker_owner;

DROP TYPE IF EXISTS deleted_comment_return CASCADE;
CREATE TYPE deleted_comment_return AS
(
    author TEXT,
    permlink TEXT
);

--17,61
CREATE OR REPLACE FUNCTION process_deleted_comment_operation(IN _operation_body JSONB)
RETURNS deleted_comment_return
LANGUAGE 'plpgsql' STABLE
AS
$$
BEGIN
  RETURN (
    ((_operation_body)->'value'->>'author')::TEXT,
    ((_operation_body)->'value'->>'permlink')::TEXT
  )::deleted_comment_return;
  
END
$$;

DROP TYPE IF EXISTS effective_vote_return CASCADE;
CREATE TYPE effective_vote_return AS
(
    author TEXT,
    voter TEXT,
    permlink TEXT,
    rshares BIGINT
);

--72
CREATE OR REPLACE FUNCTION process_effective_vote_operation(IN _operation_body JSONB)
RETURNS effective_vote_return
LANGUAGE 'plpgsql' STABLE
AS
$$
BEGIN
  RETURN (
    ((_operation_body)->'value'->>'author')::TEXT,
    ((_operation_body)->'value'->>'voter')::TEXT,
    ((_operation_body)->'value'->>'permlink')::TEXT,
    (
        CASE jsonb_typeof(_operation_body -> 'value' -> 'rshares')
        WHEN 'number' THEN
        (_operation_body -> 'value' -> 'rshares')::BIGINT
        WHEN 'string' THEN
            trim(both '"' FROM (_operation_body -> 'value' ->> 'rshares'))::BIGINT
        ELSE
          NULL::BIGINT
        END
    ) 
  )::effective_vote_return;
  
END
$$;

RESET ROLE;
