# src/providers/openai.py

from typing import Any

from llama_index.core.base.embeddings.base import BaseEmbedding
from llama_index.core.llms.llm import LLM
from llama_index.embeddings.openai import OpenAIEmbedding
from llama_index.llms.openai import OpenAI


def initialize_embed_model(
    embed_endpoint: str,
    embed_api_key: str,
    embed_model: str,
    **embed_extra: Any,
) -> BaseEmbedding:
    """
    Create OpenAI embedding model.

    Args:
        embed_model: The name of the embedding model.
        embed_endpoint: The API endpoint for the OpenAI API.
        embed_api_key: The API key for the OpenAI API.
        embed_extra: Extra Paramaters for the OpenAI API.

    Returns:
        The initialized embed_model.

    """
    # Use the provided endpoint directly.
    # Note: OpenAIEmbedding automatically picks up OPENAI_API_KEY env var
    # We are not using embed_api_key parameter here, relying on env var as original code did.
    return OpenAIEmbedding(
        model=embed_model,
        api_base=embed_endpoint,
        api_key=embed_api_key,
        **embed_extra,
    )


def initialize_llm_model(
    llm_endpoint: str,
    llm_api_key: str,
    llm_model: str,
    **llm_extra: Any,
) -> LLM:
    """
    Create OpenAI LLM model.

    Args:
        llm_model: The name of the LLM model.
        llm_endpoint: The API endpoint for the OpenAI API.
        llm_api_key: The API key for the OpenAI API.
        llm_extra: Extra paramaters for the OpenAI API.

    Returns:
        The initialized llm_model.

    """
    # Use the provided endpoint directly.
    # Note: OpenAI automatically picks up OPENAI_API_KEY env var
    # We are not using llm_api_key parameter here, relying on env var as original code did.
    return OpenAI(
        model=llm_model,
        api_base=llm_endpoint,
        api_key=llm_api_key,
        **llm_extra,
    )
