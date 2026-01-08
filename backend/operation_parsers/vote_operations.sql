SET ROLE reptracker_owner;

DROP TYPE IF EXISTS reptracker_backend.effective_vote_return CASCADE;
CREATE TYPE reptracker_backend.effective_vote_return AS
(
    author TEXT,
    voter TEXT,
    permlink TEXT,
    rshares BIGINT
);

CREATE OR REPLACE FUNCTION reptracker_backend.process_vote_impacting_operations(IN _operation_body JSONB, IN _op_type_id INT)
RETURNS reptracker_backend.effective_vote_return
LANGUAGE plpgsql
STABLE
AS
$BODY$
BEGIN
  RETURN (
    CASE
      WHEN _op_type_id = 72 THEN
        reptracker_backend.process_effective_vote_operation(_operation_body)

      ELSE
        reptracker_backend.process_deleted_comment_operation(_operation_body)
    END
  );

END;
$BODY$;

--72
CREATE OR REPLACE FUNCTION reptracker_backend.process_effective_vote_operation(IN _operation_body JSONB)
RETURNS reptracker_backend.effective_vote_return
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
  )::reptracker_backend.effective_vote_return;

END
$$;

--17,61
CREATE OR REPLACE FUNCTION reptracker_backend.process_deleted_comment_operation(IN _operation_body JSONB)
RETURNS reptracker_backend.effective_vote_return
LANGUAGE 'plpgsql' STABLE
AS
$$
BEGIN
  RETURN (
    ((_operation_body)->'value'->>'author')::TEXT,
    NULL,
    ((_operation_body)->'value'->>'permlink')::TEXT,
    NULL
  )::reptracker_backend.effective_vote_return;

END
$$;

RESET ROLE;
