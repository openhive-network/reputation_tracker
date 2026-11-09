"""PostgREST's own parameters keep their meaning through the rewriter (#18, #25).

The rewriter moves into a form body only the parameters the function declares
(endpoints/rpc_arguments.lua) and keeps every other one in the URL: PostgREST's reserved
parameters (select, columns, on_conflict, ...limit, ...offset, ...order, ...and, ...or)
and column filters. In the body PostgREST would read one as an argument the function does
not have (PGRST202), so each answer here must match a direct POST that sends the same
parameter in the query string.
"""
import pathlib
import re

import pytest

from common import direct_get, direct_post, postgrest_code, rewriter_post, via_rewriter

ENDPOINTS = pathlib.Path(__file__).resolve().parents[2] / "endpoints"
ARGS = {"account-name": "blocktrades"}


def test_no_endpoint_argument_has_a_reserved_name() -> None:
    """A GET straight to PostgREST takes these names for its own parameters, so a function
    argument with one of them could only be passed by POST. Checked against every
    reptracker_endpoints signature."""
    reserved = {"select", "columns", "on_conflict"}
    reserved_last = {"limit", "offset", "order", "and", "or"}
    signature = re.compile(r"CREATE OR REPLACE FUNCTION reptracker_endpoints\.(\w+)\s*\((.*?)\)\s*RETURNS",
                           re.S | re.I)
    seen, bad = set(), []
    for sql in ENDPOINTS.rglob("*.sql"):
        for fn, params in signature.findall(sql.read_text(encoding="utf-8")):
            seen.add(fn)
            for name in re.findall(r'"([^"]+)"', re.sub(r"--[^\n]*", "", params)):
                if name in reserved or name.rsplit(".", 1)[-1] in reserved_last:
                    bad.append(f"{fn}({name})")
    assert {"get_account_reputation", "get_rep_last_synced_block", "get_rep_sync_status",
            "get_reptracker_version", "root"} <= seen, seen
    assert not bad, bad


ROUTES = ["/accounts/blocktrades/reputation", "/get_account_reputation"]


def _via_rewriter(route, query):
    # The path route carries account-name in the path, the catch-all in the query string.
    return via_rewriter(route, query if route.startswith("/accounts/") else {**ARGS, **query})


# get_account_reputation returns one INT, on which these change nothing: they only show
# that the names are not taken as arguments (in the body they would be: PGRST202).
@pytest.mark.parametrize("query", [{"limit": "1"}, {"offset": "0", "limit": "1"}, {"select": "*"},
                                   {"order": "get_account_reputation.desc"}, {"x.limit": "1"}],
                         ids=lambda q: "&".join(q))
@pytest.mark.parametrize("route", ROUTES)
def test_reserved_parameter_is_not_an_argument(route, query) -> None:
    got = _via_rewriter(route, query)
    want = direct_post("get_account_reputation", ARGS, query=query)
    assert postgrest_code(got) != "PGRST202", got
    assert got == want


# A value PostgREST cannot parse makes it reject the parameter itself, so the answer shows
# it reached PostgREST as its own parameter: dropped, the call would succeed (200); in the
# body, it would be an unknown argument (PGRST202). (A non-numeric limit or offset would not
# do: PostgREST ignores those, answering 200; a negative limit is rejected, 416, and an
# offset for an embedding the call does not have, PGRST108.)
@pytest.mark.parametrize("query", [{"or": "garbage"}, {"and": "garbage"}, {"select": "a,("},
                                   {"limit": "-1"}, {"x.offset": "0"}],
                         ids=lambda q: "&".join(q))
@pytest.mark.parametrize("route", ROUTES)
def test_reserved_parameter_keeps_its_meaning(route, query) -> None:
    got = _via_rewriter(route, query)
    want = direct_post("get_account_reputation", ARGS, query=query)
    assert want[0] != 200 and postgrest_code(want) != "PGRST202", want
    assert got == want


OPERATOR_VALUE = {"account-name": "eq.blocktrades"}


# A column filter is a parameter no function declares, named after a result column. Every
# reptracker endpoint returns a scalar, whose one column PostgREST does not filter on
# (42703): the answer shows the filter reached PostgREST as a filter; in the body, it would
# be an unknown argument (PGRST202). The operator-prefixed argument beside it still goes to
# the body, as the split is by name, never by value.
# Cases: route, its query arguments, the function, the arguments the function receives.
@pytest.mark.parametrize("route, route_args, function, args", [
    ("/accounts/blocktrades/reputation", {}, "get_account_reputation", ARGS),
    ("/get_account_reputation", ARGS, "get_account_reputation", ARGS),
    ("/get_account_reputation", OPERATOR_VALUE, "get_account_reputation", OPERATOR_VALUE),
    ("/last-synced-block", {}, "get_rep_last_synced_block", {}),
], ids=["path", "catch-all", "catch-all-operator-value", "no-arguments"])
@pytest.mark.parametrize("operator", ["gte.0", "not.eq.0"])
def test_column_filter_keeps_its_meaning(route: str, route_args: dict[str, str], function: str,
                                         args: dict[str, str], operator: str) -> None:
    query = {function: operator}
    got = via_rewriter(route, {**route_args, **query})
    want = direct_post(function, args, query=query)
    assert want[0] == 400 and postgrest_code(want) not in ("PGRST100", "PGRST202"), want
    assert got == want


def test_calls_without_arguments_and_json_posts_unchanged() -> None:
    assert via_rewriter("/version") == direct_post("get_reptracker_version", {})
    assert via_rewriter("/sync-status") == direct_get("get_rep_sync_status", "")
    assert via_rewriter("/last-synced-block") == direct_get("get_rep_last_synced_block", "")
    # Only GETs are converted: a JSON POST goes through as sent.
    args = {"account-name": "eq.blocktrades"}
    got = rewriter_post("/get_account_reputation", args)
    want = direct_post("get_account_reputation", args)
    assert postgrest_code(want) not in ("PGRST100", "PGRST202"), want
    assert got == want
