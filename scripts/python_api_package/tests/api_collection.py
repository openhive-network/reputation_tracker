from __future__ import annotations

from beekeepy.handle.remote import AsyncSendable

from hiveio_reputation_api.reputation_api_client import ReputationApi


class ReputationApiCollection:
    def __init__(self, owner: AsyncSendable) -> None:
        self.reputation_api = ReputationApi(owner=owner)
