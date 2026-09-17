import importlib
from typing import TYPE_CHECKING, Any, cast

from llama_index.core.base.embeddings.base import BaseEmbedding
from llama_index.core.llms.llm import LLM

if TYPE_CHECKING:
    from collections.abc import Callable

from libs.logger import logger  # Assuming libs.logger exists and provides a logger instance


def initialize_embed_model(
    embed_provider: str,
    embed_model: str,
    embed_endpoint: str | None = None,
    embed_api_key: str | None = None,
    embed_extra: dict[str, Any] | None = None,
) -> BaseEmbedding:
    """
    Initialize embedding model based on specified provider and configuration.

    Dynamically loads the provider module based on the embed_provider parameter.

    Args:
        embed_provider: The name of the embedding provider (e.g., "openai", "ollama").
        embed_model: The name of the embedding model.
        embed_endpoint: The API endpoint for the embedding provider.
        embed_api_key: The API key for the embedding provider.
        embed_extra: Additional provider-specific configuration parameters.

    Returns:
        The initialized embed_model.

    Raises:
        ValueError: If the specified embed_provider is not supported or module/function not found.
        RuntimeError: If model initialization fails for the selected provider.

    """
    # Validate provider name
    error_msg = f"Invalid EMBED_PROVIDER specified: '{embed_provider}'. Provider name must be alphanumeric or contain underscores."
    if not embed_provider.replace("_", "").isalnum():
        raise ValueError(error_msg)

    try:
        provider_module = importlib.import_module(f".{embed_provider}", package="providers")
        logger.debug(f"Successfully imported provider module: providers.{embed_provider}")
        attribute = getattr(provider_module, "initialize_embed_model", None)
        if attribute is None:
            error_msg = f"Provider module '{embed_provider}' does not have an 'initialize_embed_model' function."
            raise ValueError(error_msg)

        initializer = cast("Callable[..., BaseEmbedding]", attribute)

    except ImportError as err:
        error_msg = f"Unsupported EMBED_PROVIDER specified: '{embed_provider}'. Could not find provider module 'providers.{embed_provider}"
        raise ValueError(error_msg) from err
    except AttributeError as err:
        error_msg = f"Provider module '{embed_provider}' does not have an 'initialize_embed_model' function."
        raise ValueError(error_msg) from err
    except Exception as err:
        logger.error(
            f"An unexpected error occurred while loading provider '{embed_provider}': {err!r}",
            exc_info=True,
        )
        error_msg = f"Failed to load provider '{embed_provider}' due to an unexpected error."
        raise RuntimeError(error_msg) from err

    logger.info(f"Initializing embedding model for provider: {embed_provider}")

    try:
        embedding: BaseEmbedding = initializer(
            embed_endpoint,
            embed_api_key,
            embed_model,
            **(embed_extra or {}),
        )

        logger.info(f"Embedding model initialized successfully for {embed_provider}")
        return embedding
    except TypeError as err:
        error_msg = f"Provider initializer 'initialize_embed_model' was called with incorrect arguments in '{embed_provider}'"
        logger.error(
            f"{error_msg}: {err!r}",
            exc_info=True,
        )
        raise RuntimeError(error_msg) from err
    except Exception as err:
        error_msg = f"Failed to initialize embedding model for provider '{embed_provider}'"
        logger.error(
            f"{error_msg}: {err!r}",
            exc_info=True,
        )
        raise RuntimeError(error_msg) from err


def initialize_llm_model(
    llm_provider: str,
    llm_model: str,
    llm_endpoint: str | None = None,
    llm_api_key: str | None = None,
    llm_extra: dict[str, Any] | None = None,
) -> LLM:
    """
    Create LLM model with the specified configuration.

    Dynamically loads the provider module based on the llm_provider parameter.

    Args:
        llm_provider: The name of the LLM provider (e.g., "openai", "ollama").
        llm_endpoint: The API endpoint for the LLM provider.
        llm_api_key: The API key for the LLM provider.
        llm_model: The name of the LLM model.
        llm_extra: The name of the LLM model.

    Returns:
        The initialized llm_model.

    Raises:
        ValueError: If the specified llm_provider is not supported or module/function not found.
        RuntimeError: If model initialization fails for the selected provider.

    """
    if not llm_provider.replace("_", "").isalnum():
        error_msg = f"Invalid LLM_PROVIDER specified: '{llm_provider}'. Provider name must be alphanumeric or contain underscores."
        raise ValueError(error_msg)

    try:
        provider_module = importlib.import_module(
            f".{llm_provider}",
            package="providers",
        )
        logger.debug(f"Successfully imported provider module: providers.{llm_provider}")
        attribute = getattr(provider_module, "initialize_llm_model", None)
        if attribute is None:
            error_msg = f"Provider module '{llm_provider}' does not have an 'initialize_llm_model' function."
            raise ValueError(error_msg)

        initializer = cast("Callable[..., LLM]", attribute)

    except ImportError as err:
        error_msg = f"Unsupported LLM_PROVIDER specified: '{llm_provider}'. Could not find provider module 'providers.{llm_provider}'."
        raise ValueError(error_msg) from err

    except AttributeError as err:
        error_msg = f"Provider module '{llm_provider}' does not have an 'initialize_llm_model' function."
        raise ValueError(error_msg) from err

    except Exception as e:
        error_msg = f"An unexpected error occurred while loading provider '{llm_provider}': {e}"
        logger.error(error_msg, exc_info=True)
        raise RuntimeError(error_msg) from e

    logger.info(f"Initializing LLM model for provider: '{llm_provider}'")
    logger.debug(f"Args: llm_model='{llm_model}', llm_endpoint='{llm_endpoint}'")

    try:
        llm: LLM = initializer(
            llm_endpoint,
            llm_api_key,
            llm_model,
            **(llm_extra or {}),
        )
        logger.info(f"LLM model initialized successfully for '{llm_provider}'.")

    except TypeError as e:
        error_msg = f"Provider initializer 'initialize_llm_model' in '{llm_provider}' was called with incorrect arguments: {e}"
        logger.error(error_msg, exc_info=True)
        raise RuntimeError(error_msg) from e

    except Exception as e:
        error_msg = f"Failed to initialize LLM model for provider '{llm_provider}': {e}"
        logger.error(
            error_msg,
            exc_info=True,
        )
        raise RuntimeError(error_msg) from e

    return llm
