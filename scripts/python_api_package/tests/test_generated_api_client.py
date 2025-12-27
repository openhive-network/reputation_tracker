from __future__ import annotations

from typing import Final

from beekeepy._communication.url import HttpUrl

from tests.api_caller import ReputationApiCaller

DEFAULT_ENDPOINT_FOR_TESTS: Final[HttpUrl] = HttpUrl("https://api.hive.blog")
SEARCHED_ACCOUNT_IN_TESTS: Final[str] = "gtg"

async def test_generated_api_client():
    # ARRANGE
    api_caller = ReputationApiCaller(endpoint_url=DEFAULT_ENDPOINT_FOR_TESTS)

    # ACT
    async with api_caller as api:
        result = await api.api.reputation_api.accounts_reputation(SEARCHED_ACCOUNT_IN_TESTS)

    # ASSERT
    assert isinstance(result, int), "Expected result to be an integer"
