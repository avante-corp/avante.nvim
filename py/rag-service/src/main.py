"""Command-line entry point for the RAG service."""

from __future__ import annotations

import argparse
import os
from pathlib import Path
from typing import TYPE_CHECKING

if TYPE_CHECKING:
    from fastapi import FastAPI


def parse_cli_settings() -> argparse.Namespace:
    """Argument parser."""
    # modules available in providers/ folder
    available_providers = ["openai", "openai_like", "ollama", "dashscope", "openrouter"]

    """Parse service settings from command-line arguments."""
    parser = argparse.ArgumentParser(description="Run the Avante RAG service.")
    parser.add_argument(
        "--data-dir",
        default=os.getenv("DATA_DIR"),
        help="Data directory (defaults to DATA_DIR or the XDG data directory); also stores logs when set.",
    )
    parser.add_argument(
        "--port",
        type=int,
        default=int(os.environ.get("PORT", "20250")),
        help="Port to listen on.",
    )
    parser.add_argument(
        "--workers",
        type=int,
        default=3,
        help="Number of worker processes (default: %(default)s).",
    )
    parser.add_argument(
        "--log-level",
        type=str.upper,
        choices=["CRITICAL", "ERROR", "WARNING", "INFO", "DEBUG", "NOTSET"],
        default=os.environ.get("RAG_LOG_LEVEL", "INFO").upper(),
        help="Logging level.",
    )
    parser.add_argument(
        "--embed-provider",
        default=os.getenv("RAG_EMBED_PROVIDER", "openai"),
        choices=available_providers,
        help="Embedding provider.",
    )
    parser.add_argument(
        "--embed-endpoint",
        default=os.getenv("RAG_EMBED_ENDPOINT", "https://api.openai.com/v1"),
        help="Embedding API endpoint.",
    )
    parser.add_argument(
        "--embed-model",
        default=os.getenv("RAG_EMBED_MODEL", "text-embedding-3-large"),
        help="Embedding model name.",
    )
    parser.add_argument(
        "--embed-api-key",
        default=os.getenv("RAG_EMBED_API_KEY"),
        help="Embedding API key.",
    )
    parser.add_argument(
        "--embed-extra",
        default=os.getenv("RAG_EMBED_EXTRA"),
        help="JSON object with extra embedding model settings.",
    )
    parser.add_argument(
        "--llm-provider",
        default=os.getenv("RAG_LLM_PROVIDER", "openai"),
        help="LLM provider.",
    )
    parser.add_argument(
        "--llm-endpoint",
        default=os.getenv("RAG_LLM_ENDPOINT", "https://api.openai.com/v1"),
        help="LLM API endpoint. (e.g., http://localhost:8080/v1)",
    )
    parser.add_argument(
        "--llm-model",
        default=os.getenv("RAG_LLM_MODEL", "gpt-4o-mini"),
        help="LLM model name.",
    )
    parser.add_argument(
        "--llm-api-key",
        default=os.getenv("RAG_LLM_API_KEY"),
        help="LLM API key.",
    )
    parser.add_argument(
        "--llm-extra",
        default=os.getenv("RAG_LLM_EXTRA"),
        help="JSON object with extra LLM settings.",
    )
    settings, _ = parser.parse_known_args()
    if settings.workers < 1:
        parser.error("--workers must be a positive integer")
    data_home = Path(os.environ.get("XDG_DATA_HOME", ""))
    if not data_home.is_absolute():
        data_home = Path.home() / ".local" / "share"
    settings.base_data_dir = Path(settings.data_dir) if settings.data_dir else data_home / "avante-rag-service"
    return settings


def create_app() -> FastAPI:
    """Parse worker settings before importing and initializing the service."""
    app = main(serve=False)
    assert app is not None
    return app


def main(*, serve: bool = True) -> FastAPI | None:
    """Parse arguments before importing any service dependencies."""
    cli_settings = parse_cli_settings()
    if cli_settings.data_dir:
        # Configure paths before service imports and propagate them to workers.
        os.environ["DATA_DIR"] = cli_settings.data_dir
    if serve:
        import uvicorn

        uvicorn.run(
            "main:create_app",
            factory=True,
            host="0.0.0.0",
            port=cli_settings.port,
            workers=cli_settings.workers,
        )
        return None

    from service import initialize_app

    return initialize_app(cli_settings)


if __name__ == "__main__":
    main()
