# RAG Service Configuration

This document describes how to configure the RAG service, including setting up Language Model (LLM) and Embedding providers.

## Storage directories

The service stores databases and indexing metadata in `$XDG_DATA_HOME/avante-rag-service`
(default: `~/.local/share/avante-rag-service`) and logs in
`$XDG_STATE_HOME/avante-rag-service/logs` (default: `~/.local/state/avante-rag-service/logs`).
Empty or relative XDG values use the defaults.

The embedding configuration is stored in `$XDG_CONFIG_HOME/avante/rag_config.json`
(default: `~/.config/avante/rag_config.json`), independently of `DATA_DIR` or `--data-dir`.

Passing `--data-dir /path/to/data` or setting `DATA_DIR` overrides the data location
and places logs in its `logs` subdirectory. The CLI option takes precedence over
`DATA_DIR`, preserving the layout used by the Neovim and Docker launchers. Existing data in
`/tmp/avante-rag-service` is not migrated automatically; move it to the new data
directory or set `DATA_DIR` to keep using it.

## Ignored file extensions

Directory scans load ignored extensions from `$XDG_CONFIG_HOME/avante/rag-ignore`
(default: `~/.config/avante/rag-ignore`). List one extension per line, including the
leading dot:

```text
# Skip images and archives
.png
.jpg
.zip
```

Extensions are case-insensitive; blank lines and lines starting with `#` are ignored.
When present, this file replaces the built-in binary extension list. An empty file
disables extension-based exclusions. If the file is absent, the built-in list is
used. Git ignore and git-crypt exclusions still apply.

## Provider Support Matrix

The following table shows which model types are supported by each provider:

| Provider   | LLM Support | Embedding Support |
| ---------- | ----------- | ----------------- |
| dashscope  | Yes         | Yes               |
| ollama     | Yes         | Yes               |
| openai     | Yes         | Yes               |
| openrouter | Yes         | No                |

## LLM Provider Configuration

The `llm` section in the configuration file is used to configure the Language Model (LLM) used by the RAG service.

Here are the configuration examples for each supported LLM provider:

### OpenAI LLM Configuration

[See more configurations](https://github.com/run-llama/llama_index/blob/main/llama-index-integrations/llms/llama-index-llms-openai/llama_index/llms/openai/base.py#L130)

```lua
llm = { -- Configuration for the Language Model (LLM) used by the RAG service
  provider = "openai", -- The LLM provider ("openai")
  endpoint = "https://api.openai.com/v1", -- The LLM API endpoint
  api_key = "OPENAI_API_KEY", -- The environment variable name for the LLM API key
  model = "gpt-4o-mini", -- The LLM model name (e.g., "gpt-4o-mini", "gpt-3.5-turbo")
  extra = {-- Extra configuration options for the LLM (optional)
    temperature = 0.7, -- Controls the randomness of the output. Lower values make it more deterministic.
    max_tokens = 512, -- The maximum number of tokens to generate in the completion.
    -- system_prompt = "You are a helpful assistant.", -- A system prompt to guide the model's behavior.
    -- timeout = 120, -- Request timeout in seconds.
  },
},
```

### DashScope LLM Configuration

[See more configurations](https://github.com/run-llama/llama_index/blob/main/llama-index-integrations/llms/llama-index-llms-dashscope/llama_index/llms/dashscope/base.py#L155)

```lua
llm = { -- Configuration for the Language Model (LLM) used by the RAG service
  provider = "dashscope", -- The LLM provider ("dashscope")
  endpoint = "", -- The LLM API endpoint (DashScope typically uses default or environment variables)
  api_key = "DASHSCOPE_API_KEY", -- The environment variable name for the LLM API key
  model = "qwen-plus", -- The LLM model name (e.g., "qwen-plus", "qwen-max")
  extra = nil, -- Extra configuration options for the LLM (optional)
},
```

### Ollama LLM Configuration

[See more configurations](https://github.com/run-llama/llama_index/blob/main/llama-index-integrations/llms/llama-index-llms-ollama/llama_index/llms/ollama/base.py#L65)

```lua
llm = { -- Configuration for the Language Model (LLM) used by the RAG service
  provider = "ollama", -- The LLM provider ("ollama")
  endpoint = "http://localhost:11434", -- The LLM API endpoint for Ollama
  api_key = "", -- Ollama typically does not require an API key
  model = "llama2", -- The LLM model name (e.g., "llama2", "mistral")
  extra = nil, -- Extra configuration options for the LLM (optional) Kristin", -- Extra configuration options for the LLM (optional)
},
```

### OpenRouter LLM Configuration

[See more configurations](https://github.com/run-llama/llama_index/blob/main/llama-index-integrations/llms/llama-index-llms-openrouter/llama_index/llms/openrouter/base.py#L17)

```lua
llm = { -- Configuration for the Language Model (LLM) used by the RAG service
  provider = "openrouter", -- The LLM provider ("openrouter")
  endpoint = "https://openrouter.ai/api/v1", -- The LLM API endpoint for OpenRouter
  api_key = "OPENROUTER_API_KEY", -- The environment variable name for the LLM API key
  model = "openai/gpt-4o-mini", -- The LLM model name (e.g., "openai/gpt-4o-mini", "mistralai/mistral-7b-instruct")
  extra = nil, -- Extra configuration options for the LLM (optional)
},
```

## Embedding Provider Configuration

The `embedding` section in the configuration file is used to configure the Embedding Model used by the RAG service.

Here are the configuration examples for each supported Embedding provider:

### OpenAI Embedding Configuration

[See more configurations](https://github.com/run-llama/llama_index/blob/main/llama-index-integrations/embeddings/llama-index-embeddings-openai/llama_index/embeddings/openai/base.py#L214)

```lua
embed = { -- Configuration for the Embedding Model used by the RAG service
  provider = "openai", -- The Embedding provider ("openai")
  endpoint = "https://api.openai.com/v1", -- The Embedding API endpoint
  api_key = "OPENAI_API_KEY", -- The environment variable name for the Embedding API key
  model = "text-embedding-3-large", -- The Embedding model name (e.g., "text-embedding-3-small", "text-embedding-3-large")
  extra = {-- Extra configuration options for the Embedding model (optional)
    dimensions = nil,
  },
},
```

### DashScope Embedding Configuration

[See more configurations](https://github.com/run-llama/llama_index/blob/main/llama-index-integrations/embeddings/llama-index-embeddings-dashscope/llama_index/embeddings/dashscope/base.py#L156)

```lua
embed = { -- Configuration for the Embedding Model used by the RAG service
  provider = "dashscope", -- The Embedding provider ("dashscope")
  endpoint = "", -- The Embedding API endpoint (DashScope typically uses default or environment variables)
  api_key = "DASHSCOPE_API_KEY", -- The environment variable name for the Embedding API key
  model = "text-embedding-v3", -- The Embedding model name (e.g., "text-embedding-v2")
  extra = { -- Extra configuration options for the Embedding model (optional)
    embed_batch_size = 10,
  },
},
```

### Ollama Embedding Configuration

[See more configurations](https://github.com/run-llama/llama_index/blob/main/llama-index-integrations/embeddings/llama-index-embeddings-ollama/llama_index/embeddings/ollama/base.py#L12)

```lua
embed = { -- Configuration for the Embedding Model used by the RAG service
  provider = "ollama", -- The Embedding provider ("ollama")
  endpoint = "http://localhost:11434", -- The Embedding API endpoint for Ollama
  api_key = "", -- Ollama typically does not require an API key
  model = "nomic-embed-text", -- The Embedding model name (e.g., "nomic-embed-text")
  extra = { -- Extra configuration options for the Embedding model (optional)
    embed_batch_size = 10,
    max_embedding_tokens = 512, -- Maximum tokens per chunk sent to the embedding model
  },
},
```

# CONTRIBUTING

With the python installer `uv`:

```
uv sync --python 3.13

uv run avante-rag-service --help
```
