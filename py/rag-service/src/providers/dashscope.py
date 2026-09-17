# src/providers/dashscope.py

from typing import Any

from llama_index.core.base.embeddings.base import BaseEmbedding
from llama_index.core.llms.llm import LLM
from llama_index.embeddings.dashscope import DashScopeEmbedding
from llama_index.llms.dashscope import DashScope


def initialize_embed_model(
    embed_endpoint: str,
    embed_api_key: str,
    embed_model: str,
    **embed_extra: Any,
) -> BaseEmbedding:
    """
    Create DashScope embedding model.

    Args:
        embed_endpoint: Not be used directly by the constructor.
        embed_api_key: The API key for the DashScope API.
        embed_model: The name of the embedding model.
        embed_extra: Extra parameters of the embedding model.

    Returns:
        The initialized embed_model.

    """
    # DashScope typically uses the API key and model name.
    # The endpoint might be set via environment variables or default.
    # We pass embed_api_key and embed_model to the constructor.
    # We include embed_endpoint in the signature to match the factory interface,
    # but it might not be directly used by the constructor depending on LlamaIndex's implementation.
    return DashScopeEmbedding(
        model_name=embed_model,
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
    Create DashScope LLM model.

    Args:
        llm_endpoint: Not be used directly by the constructor.
        llm_api_key: The API key for the DashScope API.
        llm_model: The name of the LLM model.
        llm_extra: Extra parameters of the LLM model.

    Returns:
        The initialized llm_model.

    """
    # DashScope typically uses the API key and model name.
    # The endpoint might be set via environment variables or default.
    # We pass llm_api_key and llm_model to the constructor.
    # We include llm_endpoint in the signature to match the factory interface,
    # but it might not be directly used by the constructor depending on LlamaIndex's implementation.
    return DashScope(
        model_name=llm_model,
        api_key=llm_api_key,
        **llm_extra,
    )
