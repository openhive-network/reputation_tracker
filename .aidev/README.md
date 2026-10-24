# Reputation tracker under AIDEV

AIDEV verifies changes to this repository through the slots in `project.yaml`,
integrates them into `aidev/integration`, and people merge that into `develop`
through merge requests (as in hive/HAfAH and hive/balance_tracker). Merge those
merge requests **keeping the source branch**: `aidev/integration` is protected, and
AIDEV's running work is based on it. GitLab CI doesn't run for AIDEV branches
(`ai/*`, `session/*`, pushes to `aidev/integration`); see `.gitlab-ci.yml`
`workflow:`. A change confined to `.aidev/` doesn't need CI's sync either
(`HAF_APP_SKIP_PATTERNS`).

## Suites

`.aidev/run-checks.sh <suite> <step>...` runs the named steps and writes
`test-results/<suite>/junit.xml`, one test case per step, with the step's log tail as
the failure body. `tavern` also writes one case per test (`tavern.xml`).

| Step | What |
|---|---|
| `shellcheck` | ShellCheck at error severity on every `*.sh` under `scripts/`, `docker/` and `tests/`, and at its default severity on `.aidev/`'s own scripts |
| `sql-registered` | every `.sql` file under `db/`, `backend/` and `endpoints/` is applied by `scripts/install_app.sh` |
| `install` | a per-run copy-on-write clone of the shared HAF (below), `scripts/install_app.sh` into it as `haf_shared_consumer`; the context `reptracker_app` must exist afterwards |
| `sync` | the candidate's own block processing over the clone's 5,000,000 blocks, run as `scripts/process_blocks.sh` runs it in the production image (`haf_app_driver.py --app=reptracker_app --lock=reputation_tracker --stop-at-block=5000000`, as `reptracker_owner`), then `ANALYZE`; then `permlinks` must carry its insert-only autovacuum reloptions and have no vacuum request, and `finish_initial_sync()` (in a rolled-back transaction) must request one `'freeze'` vacuum per table, or none on a HAF without request kinds |
| `regression` | `tests/regression` (CI's `regression-test`): every account's reputation at block 5,000,000 against hived's `reputation_api.get_account_reputations` dump `accounts_dump.json.gz`; no account may differ. The dump is loaded server-side (one `COPY`, then `reptracker_account_dump.dump_current_account_stats` per row in one statement) instead of by `data_insertion_script.py`'s one round trip per account |
| `tavern` | `.aidev/reptracker_tavern.py`: the tavern pattern tests `tests/tavern` (CI's `pattern-test`) against PostgREST over the clone, configured as `docker/docker-compose.yml`'s `backend-postgrest` (schema `reptracker_endpoints`, anonymous role `reptracker_user`, extra search path `reptracker_app`), 4 xdist workers, run from a copy in `test-results/<suite>/tavern/` (the comparator writes each answer beside its test) |
| `reinstall` | `scripts/install_app.sh` again over the installed, synced schema — an upgrade in place, as CI's `setup-scripts-test` — and the synced block must not move |
| `uninstall` | `scripts/uninstall_app.sh` (without its role statements), the leftover `reptracker_endpoints`/`reptracker_backend` schemas dropped, the context and the three schemas checked gone, then `install` again from scratch (CI's `setup-scripts-test`) |

The install steps copy `db/ backend/ endpoints/ scripts/` to a scratch directory and
write `scripts/set_version_in_sql.pgsql` there (`git rev-parse HEAD`, or `aidev` when the
checkout has no usable git), because a workflow checkout may have no `.git`.

| Slot | Steps | Shared HAF |
|---|---|---|
| quick, coverage | shellcheck, sql-registered | no |
| full, canary | those plus install, sync, regression, tavern, reinstall, uninstall | yes |
| baseline | install, sync, regression, tavern | yes |

`static` and `system` are unbound: AIDEV runs neither for a project.

## What the checks cannot see

The checks have the chain up to block 5,000,000 and nothing else. Not covered, and left
to GitLab CI:

- the advisory-lock skip path CI's `sync` job asserts (it needs the production install
  image's `install_with_app_lock.py`);
- the JMeter `performance-test` and the python API client tests (they need CI's
  generated client).

A new or changed pattern (`*.pat.json`) is expected output, and an AIDEV worker can only
derive it from existing ones by shape: it has no way to produce a value the chain
gives. For a new pattern, run the checks with the test's `.pat.json` as `{}`: the
comparator writes the actual answer next to the copied test
(`test-results/<suite>/tavern/<endpoint>/<name>.out.json`). **Check each value against
independent data** (a hived node, a block explorer) before it becomes a pattern: an
unchecked `.out.json` records whatever bug the change has as the expected value.

## The shared HAF (`sandbox.external`)

The slots without `stack: false` declare `sandbox.external: [{name: haf, provider:
haf/haf}]`: a HAF replayed to block 5000000 that an AIDEV session of the `haf` project
hosts for every HAF app's checks. AIDEV hands the suite its address as
`AIDEV_EXTERNAL_HAF_HOST`/`_PORT` and lets the runtime container reach it and nothing
else; when it is down the slot is refused as environmental, naming the provider.

`run-checks.sh` connects as `haf_shared_consumer` (trusted from the fleet LAN, no
password) and, at the first step that needs it:

1. `select haf_shared.clone_run_database('<run id>')` in database `haf_shared` returns
   `run_<run id>`, a copy-on-write clone (about a second); the run id is
   `reptracker-<suite>-<UTC time>-<random>`, so concurrent runs never share a clone;
2. grants `CREATE, CONNECT` on the clone to `reptracker_owner` and `reptracker_user`
   (the shared HAF creates both roles, as `db/builtin_roles.sql` does, and makes the
   consumer a member of `reptracker_owner`);
3. installs from the staged copy, whose `db/builtin_roles.sql` is empty (a
   non-superuser cannot run it even when the roles exist) and whose uninstall drops
   no role (`DROP OWNED BY` the app's roles would revoke their grants on every other
   run's clone too, database privileges being cluster-wide);
4. on exit, pass or fail, `haf_shared.drop_run_database('<run id>')`; a clone a killed
   run leaves behind is reaped by the provider.

Each run syncs the candidate's own block processing in its clone instead of starting
from a pre-synced reputation tracker: a change to the vote parser or the reputation
calculation has to be replayed with that code.

To run the stack checks by hand against the shared HAF (`aidev session status
haf-shared` shows its endpoint):

```bash
base="$(grep -o 'registry[^"]*haf-app-test-runner:[a-z0-9.]*' .aidev/project.yaml)"
docker build --build-arg BASE_IMAGE="$base" -f .aidev/runtime/Dockerfile -t reptracker-checks "$(mktemp -d)"
image=reptracker-checks
docker run --rm --user "$(id -u):$(id -g)" -v "$PWD:/w" -w /w \
    -e AIDEV_EXTERNAL_HAF_HOST=<host> -e AIDEV_EXTERNAL_HAF_PORT=<port> "$image" \
    .aidev/run-checks.sh full shellcheck sql-registered install sync regression tavern reinstall uninstall
```

## The test runtime image (`runtime/`)

The checks run in a container with your uid, built from `runtime/Dockerfile` on the
image `environment.base` follows: hive/common-ci-configuration's
`haf-app-test-runner:develop`, the image CI's tavern jobs run in (the
`haf_app_testing` template's default). It provides Python, `bash`, `psql`,
`shellcheck`, `postgrest`, `tavern`, `pytest`, `pytest-xdist` and `psycopg2`
at the versions common-ci-configuration's `docker-bake.hcl` defines; the Dockerfile pins
no tool version and adds only hive/tests_api (`validate_response`, the tavern tests'
comparator) at `TESTS_API_COMMIT` and `haf_app_driver.py` from
hive/common-ci-configuration at `DRIVER_COMMIT` (checksum-pinned). Nothing is installed
at run time.

AIDEV resolves the followed tag before every run and rebuilds the runtime when that tag
or the Dockerfile moves, so a tool upgrade in common-ci-configuration reaches these
checks with no commit here; a change only needs a commit when something breaks.
`environment.image` is the seed pin AIDEV's consumers read before a slot is resolved
(the base's digest at adoption); it is not the image the checks run in and does not
have to move. See AIDEV's `docs/operations/project-test-runtimes.md`, *A followed base*.
