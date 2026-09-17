"""Regression tests for indexing status response serialization."""

import unittest
from unittest.mock import patch

import service
from fastapi import FastAPI
from httpx import ASGITransport, AsyncClient
from models.indexing_history import IndexingHistory


class IndexingStatusTests(unittest.IsolatedAsyncioTestCase):
    """Exercise the status route without starting indexing or model providers."""

    async def test_indexing_status_response(self) -> None:
        """Empty and populated histories must serialize through the response model."""
        app = FastAPI()
        app.include_router(service.router)
        uri = "https://example.com/docs"
        record = IndexingHistory(uri=uri, content_hash="example-hash", status="completed")

        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
            for records in ([], [record]):
                with (
                    self.subTest(total_files=len(records)),
                    patch.object(service, "watched_resources", {}, create=True),
                    patch.object(service.indexing_history_service, "get_indexing_status", return_value=records),
                ):
                    response = await client.post("/api/v1/indexing_status", json={"uri": uri})
                    self.assertEqual(response.status_code, 200, response.text)
                    self.assertEqual(
                        response.json(),
                        {
                            "uri": uri,
                            "is_watched": False,
                            "files": [item.model_dump(mode="json") for item in records],
                            "total_files": len(records),
                            "status_summary": {"completed": 1} if records else {},
                        },
                    )


if __name__ == "__main__":
    unittest.main()
