from __future__ import annotations

from beekeepy._apis.abc.sendable import AsyncSendable

from reputation_api.reputation_api_client import ReputationApi


class ReputationApiCollection:
    def __init__(self, owner: AsyncSendable) -> None:
        self.reputation_api = ReputationApi(owner=owner)
