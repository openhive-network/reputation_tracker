"""A REST value that starts with a PostgREST operator prefix reaches its function verbatim (#18).

PostgREST reads such a GET argument as a filter (PGRST100, or the argument dropped and
PGRST202). The rewriter forwards GETs as form POSTs, so each case here must answer through
the rewriter exactly as a direct JSON POST of the same arguments does.

The only endpoint argument is get_account_reputation's account-name: covered as the path
segment the rewrite rule turns into it, and as a query parameter on the catch-all route.
Equality with the oracle proves the value was read as an argument;
test_value_arrives_unchanged checks the value itself, through the
"Account '<name>' does not exist" answer that echoes it.
"""
import pytest

from common import direct_post, postgrest_code, via_rewriter

VALUES = ["not.existing", "eq.blocktrades", "in.(gtg)", "like.gtg*", "is.null", "fts.gtg"]

PATH_ROUTE = "/accounts/{v}/reputation"
CATCH_ALL_ROUTE = "/get_account_reputation"


def _get(route, value):
    if "{v}" in route:
        return via_rewriter(route.replace("{v}", value))
    return via_rewriter(route, {"account-name": value})


@pytest.mark.parametrize("value", VALUES)
@pytest.mark.parametrize("route", [PATH_ROUTE, CATCH_ALL_ROUTE])
def test_value_reaches_function_verbatim(route, value):
    got = _get(route, value)
    want = direct_post("get_account_reputation", {"account-name": value})
    # The oracle itself must have called the function with the argument.
    assert postgrest_code(want) not in ("PGRST100", "PGRST202"), want
    assert got == want


@pytest.mark.parametrize("value", VALUES)
@pytest.mark.parametrize("route", [PATH_ROUTE, CATCH_ALL_ROUTE])
def test_value_arrives_unchanged(route, value):
    """An unknown account is answered with its name, so the value the function received is
    visible: as a path segment and as a query parameter (the catch-all route)."""
    status, body = _get(route, value)
    assert isinstance(body, dict), (status, body)
    assert body.get("message") == f"Account '{value}' does not exist", (status, body)


@pytest.mark.parametrize("route", [PATH_ROUTE, CATCH_ALL_ROUTE])
def test_ordinary_account_unchanged(route):
    got = _get(route, "blocktrades")
    assert got[0] == 200 and isinstance(got[1], int), got
    assert got == direct_post("get_account_reputation", {"account-name": "blocktrades"})
