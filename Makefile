UNAME := $(shell uname)
ARCH := $(shell uname -m)

ifeq ($(UNAME), Linux)
	OS := linux
	EXT := so
else ifeq ($(UNAME), Darwin)
	OS := macOS
	EXT := dylib
else
	$(error Unsupported operating system: $(UNAME))
endif

LUA_VERSIONS := luajit lua51

BUILD_DIR := build
BUILD_FROM_SOURCE ?= false
TARGET_LIBRARY ?= all

RAG_SERVICE_VERSION ?= 0.0.11
RAG_SERVICE_IMAGE := quay.io/yetoneful/avante-rag-service:$(RAG_SERVICE_VERSION)

all: luajit

define make_definitions
ifeq ($(BUILD_FROM_SOURCE),true)
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
else
$1:
	LUA_VERSION=$1 bash ./build.sh
endif
endef

$(foreach lua_version,$(LUA_VERSIONS),$(eval $(call make_definitions,$(lua_version))))

define build_package
$1-$2:
	cargo build --release --features=$1 -p avante-$2
	cp target/release/libavante_$(shell echo $2 | tr - _).$(EXT) $(BUILD_DIR)/avante_$(shell echo $2 | tr - _).$(EXT)
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
	@rm -rf $(BUILD_DIR)

luacheck:
	@luacheck `find \( -path './target' -prune \) -o -name "*.lua" -print` --codes

luastylecheck:
	@stylua --check lua/ plugin/ tests/

stylefix:
	@stylua lua/ plugin/

.PHONY: ruststylecheck
ruststylecheck:
	@rustup component add rustfmt 2> /dev/null
	@cargo fmt --all -- --check

.PHONY: rustlint
rustlint:
	@rustup component add clippy 2> /dev/null
	@cargo clippy -F luajit --all -- -F clippy::dbg-macro -D warnings

.PHONY: rusttest
rusttest:
	@cargo test --features luajit

.PHONY: luatest
luatest:
	@./scripts/run-luatest.sh

.PHONY: pysync
pysync:
	@cd python && uv sync

.PHONY: pytest
pytest: pysync
	@cd python && uv run pytest

# Drives real agent binaries; requires them installed and authenticated.
.PHONY: pytest-live
pytest-live: pysync
	@cd python && uv run pytest -m live

.PHONY: lint
lint: luacheck luastylecheck ruststylecheck rustlint

.PHONY: lua-typecheck
lua-typecheck:
	@./scripts/lua-typecheck.sh

.PHONY: build-image
build-image:
	docker build --platform=linux/amd64 -t $(RAG_SERVICE_IMAGE) -f py/rag-service/Dockerfile py/rag-service

.PHONY: push-image
push-image: build-image
	docker push $(RAG_SERVICE_IMAGE)
