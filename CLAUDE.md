# Reputation Tracker (reptracker)

HAF application tracking Hive account reputation scores calculated from vote operations. Reputation reflects community trust built through content voting.

## Tech Stack
- **Database**: PostgreSQL 14, PL/pgSQL
- **API**: PostgREST (REST from SQL)
- **Framework**: HAF (Hive Application Framework)
- **Testing**: Tavern (API), pytest, JMeter
- **CI/CD**: GitLab CI, Docker

## Documentation Routing

| Task | Read |
|------|------|
| Architecture/reputation algorithm | `scripts/claude/main.md` |
| Processing/sync | `scripts/claude/processing.md` |
| API endpoints | `scripts/claude/endpoints.md` |
| Tests | `scripts/claude/tests.md` |
| Debugging/CI failures | `scripts/claude/tools.md` |

## External Dependencies

**HAF (Hive Application Framework)**: HAF is installed separately (not a submodule). If you need HAF internals, ASK THE USER where HAF is cloned, then read `<haf_path>/scripts/claude/*.md`.

**Parent App**: reptracker is a submodule of HAF Block Explorer (HAFBE). HAFBE calls reptracker functions to get reputation data for accounts.

## Schema Prefix
- `reptracker_app` - Core tables and processing
- `reptracker_endpoints` - PostgREST API functions
- `reptracker_backend` - Internal helper functions

## Expansion Rules

When modifying this project, update the appropriate documentation:
- Processing functions → `scripts/claude/processing.md`
- API endpoints → `scripts/claude/endpoints.md`
- Tests → `scripts/claude/tests.md`
- Utility scripts → `scripts/claude/tools.md`
- Architecture changes → `scripts/claude/main.md`

Always reference new `.md` files from their parent index.
