UNAME := $(shell uname)
ARCH := $(shell uname -m)

ifeq ($(UNAME), Linux)
	OS := linux
	EXT := so
else ifeq ($(UNAME), Darwin)
	OS := macOS
	# looks interchangeable with "dylib", but nvim will find .so automatically in rtp
	EXT := so
	CARGO_EXT := dylib
else
	$(error Unsupported operating system: $(UNAME))
endif

CARGO_EXT ?= $(EXT)
CARGO_TARGET ?=
TARGET_DIR := target$(if $(CARGO_TARGET),/$(CARGO_TARGET))/release

LUA_VERSIONS := luajit lua51

BUILD_DIR := lua
# shortcut: directory names match library names; use Cargo metadata if they diverge.
RUST_PACKAGES := $(notdir $(patsubst %/Cargo.toml,%,$(wildcard crates/*/Cargo.toml)))

export AVANTE_RUNTIME_TEST_DIR ?= $(CURDIR)/target/tests
export DEPS_PATH ?= $(AVANTE_RUNTIME_TEST_DIR)/deps
ACP_INTEGRATION_DIR := $(AVANTE_RUNTIME_TEST_DIR)/acp-integration

RAG_SERVICE_VERSION ?= 0.0.11
RAG_SERVICE_IMAGE := quay.io/yetoneful/avante-rag-service:$(RAG_SERVICE_VERSION)

all: luajit

define build_runtime
.PHONY: $1
$1: | $(BUILD_DIR)
	cargo build --workspace --release --no-default-features --features=$1 $(if $(CARGO_TARGET),--target $(CARGO_TARGET))
	for library in $(subst -,_,$(RUST_PACKAGES)); do \
		rm -f "$(BUILD_DIR)/$$$$library.$(EXT)" || exit; \
		cp "$(TARGET_DIR)/lib$$$$library.$(CARGO_EXT)" "$(BUILD_DIR)/$$$$library.$(EXT)" || exit; \
	done
endef

$(foreach lua_version,$(LUA_VERSIONS),$(eval $(call build_runtime,$(lua_version))))

$(BUILD_DIR):
	@mkdir -p $(BUILD_DIR)

clean:
	@rm -rf $(BUILD_DIR)/*.$(EXT)

pre-commit:
	pre-commit run --all-files --show-diff-on-failure

.PHONY: docgen
docgen:
	vimcats --prefix-func \
		lua/avante/init.lua \
		lua/avante/config.lua \
		lua/avante/api.lua \
		lua/avante/commands.lua \
		lua/avante/sidebar.lua \
		lua/avante/slashcommands.lua \
		lua/cmp_avante/mentions.lua \
		lua/avante/rag_service.lua \
		lua/avante/llm_tools/init.lua \
		lua/avante/llm_tools/bash.lua \
		lua/avante/llm_tools/web_search.lua \
		lua/avante/utils/prompts.lua \
		lua/avante/extensions/init.lua \
		lua/avante/utils/init.lua \
		lua/avante/utils/curl.lua \
		lua/avante/libs/acp_client.lua \
		lua/avante/providers/init.lua \
		lua/avante/providers/bedrock.lua \
		lua/avante/providers/claude.lua \
		lua/avante/providers/ollama.lua \
		lua/avante/providers/openai.lua \
		lua/avante/html2md.lua \
		lua/avante/path.lua \
		lua/avante/faq.lua \
		> doc/avante.txt
	nvim -u NONE -i NONE --headless +'helptags doc' +'quit!'

luacheck:
	luacheck `find \( -path './target' -prune \) -o -name "*.lua" -print` --codes

luastylecheck:
	stylua --check lua/ plugin/ tests/

stylefix:
	stylua lua/ plugin/

.PHONY: ruststylecheck
ruststylecheck:
	cargo fmt --all -- --check

.PHONY: rustlint
rustlint:
	cargo clippy -F luajit --all -- -F clippy::dbg-macro -D warnings

.PHONY: rusttest
rusttest:
	cargo test --release --no-default-features --features=luajit $(if $(CARGO_TARGET),--target $(CARGO_TARGET))

.PHONY: luatest
luatest:
	./scripts/run-luatest.sh

.PHONY: nvim-build
nvim-build:
	mkdir -p ~/.cache/nvim
	nvim -V3nvim.log --headless -u NONE \
		--cmd "set rtp^=." \
		--cmd 'lua local deps = vim.env.DEPS_PATH .. "/share/lua/5.1/"; package.path = deps .. "?.lua;" .. deps .. "?/init.lua;" .. package.path' \
		-c "runtime plugin/avante.lua" \
		-c "lua vim.g.avante = { debug = vim.log.levels.INFO }" \
		-c "AvanteBuild source=true" +quit!

.PHONY: acp-integration-test
acp-integration-test:
	mkdir -p "$(ACP_INTEGRATION_DIR)"
	cp "$(TARGET_DIR)/libavante_acp.$(CARGO_EXT)" "$(ACP_INTEGRATION_DIR)/avante_acp.$(EXT)"
	rustc --edition=2024 \
		-o "$(ACP_INTEGRATION_DIR)/stdio-agent" \
		crates/avante-acp/tests/fixtures/stdio_agent.rs
	AVANTE_ACP_TEST_AGENT="$(ACP_INTEGRATION_DIR)/stdio-agent" \
		AVANTE_ACP_TEST_NATIVE_DIR="$(ACP_INTEGRATION_DIR)" \
		./scripts/run-luatest.sh tests/integration/acp_native_spec.lua

# upgrade / pin CI actions
.PHONY: upgrade-actions
upgrade-actions:
	# install with gh extension install github/gh-actions-lock
	gh actions-lock --relock

.PHONY: print-deps-path
print-deps-path:
	@printf '%s\n' "$(DEPS_PATH)"

.PHONY: setup-deps
setup-deps:
	./scripts/setup-deps.sh clone "$(DEPS_PATH)"
	./scripts/setup-deps.sh generate-luarc "$(AVANTE_RUNTIME_TEST_DIR)/luarc.json"

.PHONY: lint
lint: luacheck luastylecheck ruststylecheck rustlint

.PHONY: .luarc.json
.luarc.json:
	./scripts/setup-deps.sh generate-luarc ./.luarc.json

.PHONY: lua-typecheck
lua-typecheck:
	./scripts/lua-typecheck.sh

.PHONY: build-image
build-image:
	docker build --platform=linux/amd64 -t $(RAG_SERVICE_IMAGE) -f py/rag-service/Dockerfile py/rag-service

.PHONY: push-image
push-image: build-image
	docker push $(RAG_SERVICE_IMAGE)

.PHONY: docker-run
docker-run:
	nix build .#dockerImage && docker load < result && docker run --rm -it avante-nvim:latest


.PHONY: rag-venv
rag-venv:
	uv venv --python 3.14
	source .venv/bin/activate && uv pip install py/rag-service


.PHONY: rag-start
rag-start:
	# append your flags to this command
	cd py/rag-service && uv run avante-rag-service
