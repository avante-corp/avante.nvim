import json
import os
from datetime import datetime
from typing import Any

from libs.db import get_db_connection
from libs.logger import logger
from libs.utils import get_node_uri
from llama_index.core.schema import Document
from models.indexing_history import IndexingHistory


class IndexingHistoryService:
    def delete_indexing_status(self, uri: str) -> None:
        """Delete indexing status for a specific file."""
        with get_db_connection() as conn:
            conn.execute(
                """
              DELETE FROM indexing_history
              WHERE uri = ?
              """,
                (uri,),
            )
            conn.commit()

    def delete_indexing_status_by_document_id(self, document_id: str) -> None:
        """Delete indexing status for a specific document."""
        with get_db_connection() as conn:
            conn.execute(
                """
              DELETE FROM indexing_history
              WHERE document_id = ?
              """,
                (document_id,),
            )
            conn.commit()

    def update_indexing_status(
        self,
        doc: Document,
        status: str,
        error_message: str | None = None,
        metadata: dict[str, Any] | None = None,
    ) -> None:
        """Update the indexing status in the database."""
        content_hash = doc.hash

        # Get URI from metadata if available
        uri = get_node_uri(doc)
        if not uri:
            logger.warning("URI not found for document: %s", doc.doc_id)
            return

        record = IndexingHistory(
            id=None,
            uri=uri,
            content_hash=content_hash,
            status=status,
            error_message=error_message,
            document_id=doc.doc_id,
            metadata=metadata,
        )
        with get_db_connection() as conn:
            # Check if record exists
            existing = conn.execute(
                "SELECT id FROM indexing_history WHERE document_id = ?",
                (doc.doc_id,),
            ).fetchone()

            if existing:
                # Update existing record
                conn.execute(
                    """
                  UPDATE indexing_history
                  SET content_hash = ?, status = ?, error_message = ?, document_id = ?, metadata = ?
                  WHERE uri = ?
                  """,
                    (
                        record.content_hash,
                        record.status,
                        record.error_message,
                        record.document_id,
                        json.dumps(record.metadata) if record.metadata else None,
                        record.uri,
                    ),
                )
            else:
                # Insert new record
                conn.execute(
                    """
                  INSERT INTO indexing_history
                  (uri, content_hash, status, error_message, document_id, metadata)
                  VALUES (?, ?, ?, ?, ?, ?)
                  """,
                    (
                        record.uri,
                        record.content_hash,
                        record.status,
                        record.error_message,
                        record.document_id,
                        json.dumps(record.metadata) if record.metadata else None,
                    ),
                )
            conn.commit()

    def get_indexing_status(self, doc: Document | None = None, base_uri: str | None = None) -> list[IndexingHistory]:
        """Get indexing status from the database."""
        with get_db_connection() as conn:
            if doc:
                uri = get_node_uri(doc)
                if not uri:
                    logger.warning("URI not found for document: %s", doc.doc_id)
                    return []
                content_hash = doc.hash
                # For a specific file, get its latest status
                query = """
                  SELECT *
                  FROM indexing_history
                  WHERE uri = ? and content_hash = ?
                  ORDER BY timestamp DESC LIMIT 1
              """
                params = (uri, content_hash)
            elif base_uri:
                # For files in a specific directory, get their latest status
                query = """
                  WITH RankedHistory AS (
                      SELECT *,
                             ROW_NUMBER() OVER (PARTITION BY document_id ORDER BY timestamp DESC) as rn
                      FROM indexing_history
                      WHERE uri LIKE ? || '%'
                  )
                  SELECT id, uri, content_hash, status, timestamp, error_message, document_id, metadata
                  FROM RankedHistory
                  WHERE rn = 1
                  ORDER BY timestamp DESC
              """
                params = (base_uri,) if base_uri.endswith(os.path.sep) else (base_uri + os.path.sep,)
            else:
                # For all files, get their latest status
                query = """
                  WITH RankedHistory AS (
                      SELECT *,
                             ROW_NUMBER() OVER (PARTITION BY uri ORDER BY timestamp DESC) as rn
                      FROM indexing_history
                  )
                  SELECT id, uri, content_hash, status, timestamp, error_message, document_id, metadata
                  FROM RankedHistory
                  WHERE rn = 1
                  ORDER BY timestamp DESC
              """
                params = ()

            rows = conn.execute(query, params).fetchall()

            result = []
            for row in rows:
                row_dict = dict(row)
                # Parse metadata JSON if it exists
                if row_dict.get("metadata"):
                    try:
                        row_dict["metadata"] = json.loads(row_dict["metadata"])
                    except json.JSONDecodeError:
                        row_dict["metadata"] = None
                # Parse timestamp string to datetime if needed
                if isinstance(row_dict.get("timestamp"), str):
                    row_dict["timestamp"] = datetime.fromisoformat(
                        row_dict["timestamp"],
                    )
                result.append(IndexingHistory(**row_dict))

            return result


indexing_history_service = IndexingHistoryService()
