"""PostgREST's own parameters keep their meaning through the rewriter (#18).

The rewriter moves a GET's function arguments into a form body but keeps PostgREST's
reserved parameters (select, columns, on_conflict, ...limit, ...offset, ...order, ...and,
...or) in the URL. In the body PostgREST would read one as an argument the function does
not have (PGRST202), so each answer here must match a direct POST that sends the same
parameter in the query string.
"""
import pathlib
import re

import pytest

from common import direct_get, direct_post, postgrest_code, rewriter_post, via_rewriter

ENDPOINTS = pathlib.Path(__file__).resolve().parents[2] / "endpoints"
ARGS = {"account-name": "blocktrades"}


def test_no_endpoint_argument_has_a_reserved_name():
    """The rewriter keeps these names in the URL, so a function argument with one of them
    would never reach the function. Checked against every reptracker_endpoints signature."""
    reserved = {"select", "columns", "on_conflict"}
    reserved_last = {"limit", "offset", "order", "and", "or"}
    signature = re.compile(r"CREATE OR REPLACE FUNCTION reptracker_endpoints\.(\w+)\s*\((.*?)\)\s*RETURNS",
                           re.S | re.I)
    seen, bad = 0, []
    for sql in ENDPOINTS.rglob("*.sql"):
        for fn, params in signature.findall(sql.read_text(encoding="utf-8")):
            seen += 1
            for name in re.findall(r'"([^"]+)"', re.sub(r"--[^\n]*", "", params)):
                if name in reserved or name.rsplit(".", 1)[-1] in reserved_last:
                    bad.append(f"{fn}({name})")
    assert seen >= 4, f"found only {seen} endpoint signatures under {ENDPOINTS}"
    assert not bad, bad


@pytest.mark.parametrize("query", [{"limit": "1"}, {"offset": "0", "limit": "1"}, {"select": "*"}],
                         ids=lambda q: "&".join(q))
@pytest.mark.parametrize("route", ["/accounts/blocktrades/reputation", "/get_account_reputation"])
def test_reserved_parameter_stays_in_the_url(route, query):
    # The path route carries account-name in the path, the catch-all in the query string.
    params = query if route.startswith("/accounts/") else {**ARGS, **query}
    got = via_rewriter(route, params)
    want = direct_post("get_account_reputation", ARGS, query=query)
    assert postgrest_code(got) != "PGRST202", got
    assert got == want


def test_calls_without_arguments_and_json_posts_unchanged():
    assert via_rewriter("/version") == direct_post("get_reptracker_version", {})
    assert via_rewriter("/sync-status") == direct_get("get_rep_sync_status", "")
    assert via_rewriter("/last-synced-block") == direct_get("get_rep_last_synced_block", "")
    # Only GETs are converted: a JSON POST goes through as sent.
    args = {"account-name": "eq.blocktrades"}
    got = rewriter_post("/get_account_reputation", args)
    want = direct_post("get_account_reputation", args)
    assert postgrest_code(want) not in ("PGRST100", "PGRST202"), want
    assert got == want
