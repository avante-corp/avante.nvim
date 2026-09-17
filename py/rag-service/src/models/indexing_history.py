"""Indexing History Model."""

from datetime import datetime
from typing import Any

from pydantic import BaseModel, Field


class IndexingHistory(BaseModel):
    """Model for indexing history record."""

    id: int | None = Field(default=None, description="Record ID")
    uri: str = Field(..., description="URI of the indexed file")
    content_hash: str = Field(..., description="MD5 hash of the file content")
    status: str = Field(..., description="Indexing status (indexing/completed/failed)")
    timestamp: datetime = Field(default_factory=datetime.now, description="Record timestamp")
    error_message: str | None = Field(default=None, description="Error message if failed")
    document_id: str | None = Field(default=None, description="Document ID in the index")
    metadata: dict[str, Any] | None = Field(default=None, description="Additional metadata")
