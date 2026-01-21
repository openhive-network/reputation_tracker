from __future__ import annotations

from typing import Final

import aiohttp

from beekeepy._communication.url import HttpUrl

from tests.api_caller import ReputationApiCaller

FALLBACK_ENDPOINTS: Final[list[HttpUrl]] = [
    HttpUrl("https://api.syncad.com"),
    HttpUrl("https://api.hive.blog"),
]
SEARCHED_ACCOUNT_IN_TESTS: Final[str] = "gtg"


async def _get_healthy_endpoint(endpoints: list[HttpUrl], service_path: str) -> HttpUrl:
    """Return the first endpoint where the service responds with 2xx status."""
    async with aiohttp.ClientSession() as session:
        for endpoint in endpoints:
            try:
                url = f"{endpoint}{service_path}"
                async with session.get(url, timeout=aiohttp.ClientTimeout(total=5)) as response:
                    if response.status < 400:
                        return endpoint
            except (aiohttp.ClientError, TimeoutError):
                continue
    raise ValueError(f"No healthy endpoint found for service path: {service_path}")


async def test_generated_api_client():
    # ARRANGE
    endpoint = await _get_healthy_endpoint(FALLBACK_ENDPOINTS, f"/reputation-api/accounts/{SEARCHED_ACCOUNT_IN_TESTS}/reputation")
    api_caller = ReputationApiCaller(endpoint_url=endpoint)

    # ACT
    async with api_caller as api:
        result = await api.api.reputation_api.accounts_reputation(SEARCHED_ACCOUNT_IN_TESTS)

    # ASSERT
    assert isinstance(result, int), "Expected result to be an integer"
