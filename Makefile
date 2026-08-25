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
TARGET_LIBRARY ?= all

RAG_SERVICE_VERSION ?= 0.0.11
RAG_SERVICE_IMAGE := quay.io/yetoneful/avante-rag-service:$(RAG_SERVICE_VERSION)

all: luajit

define make_definitions
ifeq ($(TARGET_LIBRARY), all)
$1: $(BUILD_DIR)/libAvanteTokenizers-$1.$(EXT) $(BUILD_DIR)/libAvanteTemplates-$1.$(EXT) $(BUILD_DIR)/libAvanteRepoMap-$1.$(EXT) $(BUILD_DIR)/libAvanteHtml2md-$1.$(EXT)
else ifeq ($(TARGET_LIBRARY), tokenizers)
$1: $(BUILD_DIR)/libAvanteTokenizers-$1.$(EXT)
else ifeq ($(TARGET_LIBRARY), templates)
$1: $(BUILD_DIR)/libAvanteTemplates-$1.$(EXT)
else ifeq ($(TARGET_LIBRARY), repo-map)
$1: $(BUILD_DIR)/libAvanteRepoMap-$1.$(EXT)
else ifeq ($(TARGET_LIBRARY), html2md)
$1: $(BUILD_DIR)/libAvanteHtml2md-$1.$(EXT)
else
	$$(error TARGET_LIBRARY must be one of all, tokenizers, templates, repo-map, html2md)
endif
endef

$(foreach lua_version,$(LUA_VERSIONS),$(eval $(call make_definitions,$(lua_version))))

define build_package
$1-$2:
	cargo build --release --features=$1 -p avante-$2 $(if $(CARGO_TARGET),--target $(CARGO_TARGET))
	cp $(TARGET_DIR)/libavante_$(shell echo $2 | tr - _).$(CARGO_EXT) $(BUILD_DIR)/avante_$(shell echo $2 | tr - _).$(EXT)
endef

define build_targets
$(BUILD_DIR)/libAvanteTokenizers-$1.$(EXT): $(BUILD_DIR) $1-tokenizers
$(BUILD_DIR)/libAvanteTemplates-$1.$(EXT): $(BUILD_DIR) $1-templates
$(BUILD_DIR)/libAvanteRepoMap-$1.$(EXT): $(BUILD_DIR) $1-repo-map
$(BUILD_DIR)/libAvanteHtml2md-$1.$(EXT): $(BUILD_DIR) $1-html2md
endef

$(foreach lua_version,$(LUA_VERSIONS),$(eval $(call build_package,$(lua_version),tokenizers)))
$(foreach lua_version,$(LUA_VERSIONS),$(eval $(call build_package,$(lua_version),templates)))
$(foreach lua_version,$(LUA_VERSIONS),$(eval $(call build_package,$(lua_version),repo-map)))
$(foreach lua_version,$(LUA_VERSIONS),$(eval $(call build_package,$(lua_version),html2md)))
$(foreach lua_version,$(LUA_VERSIONS),$(eval $(call build_targets,$(lua_version))))

$(BUILD_DIR):
	@mkdir -p $(BUILD_DIR)

clean:
	@rm -rf $(BUILD_DIR)/*.$(EXT)

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
		lua/avante/utils/prompts.lua \
		lua/avante/extensions/init.lua \
		lua/avante/utils/init.lua \
		lua/avante/libs/acp_client.lua \
		lua/avante/providers/init.lua \
		lua/avante/providers/bedrock.lua \
		lua/avante/providers/claude.lua \
		lua/avante/providers/ollama.lua \
		lua/avante/providers/openai.lua \
		lua/avante/html2md.lua \
		lua/avante/faq.lua \
		> doc/avante.txt
	nvim -u NONE -i NONE --headless +'helptags doc' +'quit!'

luacheck:
	@luacheck `find \( -path './target' -prune \) -o -name "*.lua" -print` --codes

luastylecheck:
	@stylua --check lua/ plugin/ tests/

stylefix:
	@stylua lua/ plugin/

.PHONY: ruststylecheck
ruststylecheck:
	cargo fmt --all -- --check

.PHONY: rustlint
rustlint:
	cargo clippy -F luajit --all -- -F clippy::dbg-macro -D warnings

.PHONY: rusttest
rusttest:
	@cargo test --features luajit

.PHONY: luatest
luatest:
	@./scripts/run-luatest.sh

# upgrade / pin CI actions
.PHONY: upgrade-actions
upgrade-actions:
	ratchet upgrade ./.github/workflows/rust.yaml .github/actions/build/action.yaml

.PHONY: lint
lint: luacheck luastylecheck ruststylecheck rustlint

.PHONY: .luarc.json
.luarc.json:
	./scripts/setup-deps.sh generate-luarc ./.luarc.json

.PHONY: lua-typecheck
lua-typecheck:
	@./scripts/lua-typecheck.sh

.PHONY: build-image
build-image:
	docker build --platform=linux/amd64 -t $(RAG_SERVICE_IMAGE) -f py/rag-service/Dockerfile py/rag-service

.PHONY: push-image
push-image: build-image
	docker push $(RAG_SERVICE_IMAGE)
