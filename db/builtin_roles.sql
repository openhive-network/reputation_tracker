/**
 * Database Roles for Reputation Tracker
 * ======================================
 *
 * This file defines the two database roles required by Reputation Tracker:
 *
 * reptracker_owner
 * ----------------
 * - Owner role with full read/write access to all Reputation Tracker schemas
 * - Used by: Block processing scripts, schema migrations, admin operations
 * - Inherits from: hive_applications_owner_group (HAF role for app owners)
 * - Can create schemas, tables, functions, and process blocks
 *
 * reptracker_user
 * ---------------
 * - Read-only role for API access
 * - Used by: PostgREST (API server), read-only queries
 * - Inherits from: hive_applications_group (HAF role for app users)
 * - Can only SELECT from tables, cannot modify data
 *
 * Role Hierarchy:
 * ---------------
 *   haf_admin
 *       └── reptracker_owner (schema owner, block processor)
 *               └── reptracker_user (API read-only access)
 *
 * Security Model:
 * ---------------
 * - All schema objects are owned by reptracker_owner
 * - reptracker_user is granted SELECT on tables after installation
 * - PostgREST connects as reptracker_user for safe API access
 * - Block processing runs as reptracker_owner for write access
 */

-- Create schema owner role (used for migrations and block processing)
DO $$
BEGIN
  CREATE ROLE reptracker_owner WITH LOGIN INHERIT IN ROLE hive_applications_owner_group;
EXCEPTION WHEN duplicate_object THEN RAISE NOTICE '%, skipping', SQLERRM USING ERRCODE = SQLSTATE;
END
$$;

-- Create API user role (read-only access via PostgREST)
DO $$
BEGIN
  CREATE ROLE reptracker_user WITH LOGIN INHERIT IN ROLE hive_applications_group;
EXCEPTION WHEN duplicate_object THEN RAISE NOTICE '%, skipping', SQLERRM USING ERRCODE = SQLSTATE;
END
$$;

-- Allow haf_admin to act as reptracker_owner (for installation scripts)
GRANT reptracker_owner TO haf_admin;

-- Allow reptracker_owner to act as reptracker_user (for testing)
GRANT reptracker_user TO reptracker_owner;
