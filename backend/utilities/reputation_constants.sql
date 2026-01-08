SET ROLE reptracker_owner;

-- Reputation calculation constants for Reputation Tracker
-- These define the protocol constants used in reputation scoring
--
-- Reputation System Overview:
-- ---------------------------
-- Raw reputation is accumulated from vote rshares (reward shares).
-- The formula dampens vote impact: reputation_change = rshares >> 6 (divide by 64)
--
-- Display reputation transforms raw values to a human-readable score:
--   score = (log10(abs(raw_rep)) - 9) * 9 + 25
--   negative_rep => score = -score
--
-- This produces scores roughly in the range 25-75 for typical accounts.

-- Reputation scaling factor (rshares to reputation conversion)
-- The >> 6 bit shift is equivalent to dividing by 64
-- This dampening prevents high-stake votes from dominating reputation
CREATE OR REPLACE FUNCTION reptracker_backend.reputation_scaling_bits()
RETURNS INT LANGUAGE plpgsql IMMUTABLE AS $$
BEGIN
  RETURN 6;
END;
$$;

-- Display formula constants
-- Base for logarithm transformation
CREATE OR REPLACE FUNCTION reptracker_backend.reputation_log_base()
RETURNS INT LANGUAGE plpgsql IMMUTABLE AS $$
BEGIN
  RETURN 10;
END;
$$;

-- Logarithm offset (subtracted from log result)
-- Accounts with raw rep ~10^9 will have log offset = 0
CREATE OR REPLACE FUNCTION reptracker_backend.reputation_log_offset()
RETURNS INT LANGUAGE plpgsql IMMUTABLE AS $$
BEGIN
  RETURN 9;
END;
$$;

-- Multiplier applied after log offset
CREATE OR REPLACE FUNCTION reptracker_backend.reputation_multiplier()
RETURNS INT LANGUAGE plpgsql IMMUTABLE AS $$
BEGIN
  RETURN 9;
END;
$$;

-- Base score offset (default reputation for new accounts)
CREATE OR REPLACE FUNCTION reptracker_backend.reputation_base_score()
RETURNS INT LANGUAGE plpgsql IMMUTABLE AS $$
BEGIN
  RETURN 25;
END;
$$;

RESET ROLE;
