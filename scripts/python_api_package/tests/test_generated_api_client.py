from __future__ import annotations

from typing import Final

from beekeepy._communication.is_url_reachable import async_get_first_reachable_url
from beekeepy._communication.url import HttpUrl

from tests.api_caller import ReputationApiCaller

FALLBACK_ENDPOINTS: Final[list[HttpUrl]] = [
    HttpUrl("https://api.syncad.com"),
    HttpUrl("https://api.hive.blog"),
]
SEARCHED_ACCOUNT_IN_TESTS: Final[str] = "gtg"


async def test_generated_api_client():
    # ARRANGE
    endpoint = await async_get_first_reachable_url(FALLBACK_ENDPOINTS)
    api_caller = ReputationApiCaller(endpoint_url=endpoint)

    # ACT
    async with api_caller as api:
        result = await api.api.reputation_api.accounts_reputation(SEARCHED_ACCOUNT_IN_TESTS)

    # ASSERT
    assert isinstance(result, int), "Expected result to be an integer"
