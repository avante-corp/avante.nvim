"""Regression tests for retrieval error responses."""

import unittest
from unittest.mock import Mock, patch

import service
from fastapi import FastAPI
from httpx2 import ASGITransport, AsyncClient, Request
from openai import APITimeoutError


class RetrieveTests(unittest.IsolatedAsyncioTestCase):
    """Exercise retrieval without starting indexing or model providers."""

    async def test_provider_timeout(self) -> None:
        """Provider timeouts must reach the client as a descriptive HTTP 504."""
        app = FastAPI()
        app.include_router(service.router)
        index = Mock()
        error = APITimeoutError(request=Request("POST", "http://provider/embeddings"))
        index.as_query_engine.return_value.query.side_effect = error

        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
            with patch.object(service, "index", index, create=True):
                response = await client.post(
                    "/api/v1/retrieve",
                    json={"query": "Explain this project", "base_uri": "https://example.com/docs"},
                )

        self.assertEqual(response.status_code, 504)
        self.assertEqual(response.json(), {"detail": f"Model provider timed out during retrieval: {error.message}"})


if __name__ == "__main__":
    unittest.main()
