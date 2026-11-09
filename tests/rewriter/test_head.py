"""A HEAD through the rewriter answers as its GET does, without a body (#25).

The rewriter forwards a HEAD of a function as a form POST, as it does a GET, and gives
the answer its HEAD back so nginx sends no body. A body after a HEAD's headers would be
read as the start of the next answer on the same connection, so each case sends the HEAD
and then a GET on one keep-alive connection.
"""
import http.client
import json
from urllib.parse import urlsplit

import pytest

from common import REWRITER, TIMEOUT_S, via_rewriter

PATHS = ["/accounts/blocktrades/reputation", "/accounts/not.blocktrades/reputation",
         "/get_account_reputation?account-name=eq.blocktrades", "/version"]


def _request(conn: http.client.HTTPConnection, method: str, path: str) -> tuple[int, bytes]:
    conn.request(method, path)
    resp = conn.getresponse()
    return resp.status, resp.read()


@pytest.mark.parametrize("path", PATHS)
def test_head_answers_as_get_without_body(path: str) -> None:
    url = urlsplit(REWRITER)
    assert url.hostname is not None, REWRITER
    conn = http.client.HTTPConnection(url.hostname, url.port, timeout=TIMEOUT_S)
    try:
        head_status, head_body = _request(conn, "HEAD", path)
        get_status, get_body = _request(conn, "GET", path)
    finally:
        conn.close()
    want_status, want_body = via_rewriter(path)
    assert head_status == want_status and head_body == b"", (head_status, head_body)
    assert (get_status, json.loads(get_body)) == (want_status, want_body)
