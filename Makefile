# Thin ergonomic wrapper over CMake.
# Usage: make [TARGET]  [BUILD_DIR=build] [GENERATOR=Ninja]
#
# Examples:
#   make                 # ensure deps from source + configure + build
#   make deps            # build OpenSSL + LibVNCServer from source only
#   make GENERATOR=Ninja
#   make UNIVERSAL=OFF   # native arch (deps + app)
#   make test
#   make coverage
#   make format
#   make tidy
#   make launchd-load

BUILD_DIR  ?= build
GENERATOR  ?=
PREFIX     ?=
UNIVERSAL  ?= ON
COVERAGE   ?= OFF
JOBS       ?=
DEPS_ARCH  ?=

CMAKE_FLAGS := -DMACVNC_UNIVERSAL=$(UNIVERSAL) -DMACVNC_ENABLE_COVERAGE=$(COVERAGE)
ifneq ($(PREFIX),)
  CMAKE_FLAGS += -DMACVNC_DEPS_PREFIX=$(PREFIX)
endif

CMAKE_GEN :=
ifneq ($(GENERATOR),)
  CMAKE_GEN := -G "$(GENERATOR)"
endif

BUILD_OPTS :=
ifneq ($(JOBS),)
  BUILD_OPTS += -j$(JOBS)
endif

DEPS_ARGS :=
ifneq ($(DEPS_ARCH),)
  DEPS_ARGS += --arch=$(DEPS_ARCH)
endif
ifneq ($(JOBS),)
  export JOBS
endif

.DEFAULT_GOAL := all

.PHONY: help
help: ## List targets and current variable defaults
	@awk 'BEGIN {FS = ":.*## "; printf "Usage:\n  make \033[36m<target>\033[0m\n\nTargets:\n"} \
		/^[a-zA-Z0-9_.-]+:.*## / { printf "  \033[36m%-18s\033[0m %s\n", $$1, $$2 }' \
		$(MAKEFILE_LIST)
	@printf "\nVariables:\n"
	@printf "  %-18s %s\n" "BUILD_DIR" "$(BUILD_DIR)"
	@printf "  %-18s %s\n" "GENERATOR" "$(GENERATOR)"
	@printf "  %-18s %s\n" "UNIVERSAL" "$(UNIVERSAL)"
	@printf "  %-18s %s\n" "COVERAGE" "$(COVERAGE)"
	@printf "  %-18s %s\n" "PREFIX" "$(PREFIX)"
	@printf "  %-18s %s\n" "DEPS_ARCH" "$(DEPS_ARCH)"
	@printf "  %-18s %s\n" "JOBS" "$(JOBS)"

.PHONY: deps
deps: ## Build OpenSSL + LibVNCServer from source (see scripts/build-deps.sh)
	./scripts/build-deps.sh $(DEPS_ARGS)

# Stamp / library that configure requires. UNIVERSAL=ON needs fat libs;
# UNIVERSAL=OFF can use a single host-arch prefix (faster).
DEPS_UNIVERSAL_LIB := deps/prefix/universal/lib/libvncserver.a
DEPS_HOST_LIB := deps/prefix/$(shell uname -m)/lib/libvncserver.a

.PHONY: ensure-deps
ensure-deps: ## Build from-source deps if missing (honours UNIVERSAL / DEPS_ARCH)
ifeq ($(UNIVERSAL),ON)
	@need=0; \
	if [[ ! -f "$(DEPS_UNIVERSAL_LIB)" ]]; then need=1; \
	else \
	  archs=$$(lipo -archs "$(DEPS_UNIVERSAL_LIB)" 2>/dev/null || true); \
	  echo "$$archs" | grep -q arm64 || need=1; \
	  echo "$$archs" | grep -q x86_64 || need=1; \
	fi; \
	if [[ $$need -eq 1 ]]; then \
	  echo "Building from-source dependencies (universal)…"; \
	  ./scripts/build-deps.sh $(DEPS_ARGS); \
	fi
else
	@if [[ ! -f "$(DEPS_HOST_LIB)" && ! -f "$(DEPS_UNIVERSAL_LIB)" ]]; then \
	  echo "Building from-source dependencies ($(shell uname -m))…"; \
	  if [[ -n "$(DEPS_ARCH)" ]]; then \
	    ./scripts/build-deps.sh $(DEPS_ARGS); \
	  else \
	    ./scripts/build-deps.sh --arch=$$(uname -m); \
	  fi; \
	fi
endif

.PHONY: all
all: build ## Configure (if needed) and build

.PHONY: configure
configure: ensure-deps ## Ensure deps, then cmake configure into BUILD_DIR
	env -u PKG_CONFIG_PATH -u LDFLAGS -u CPPFLAGS \
	  cmake -S . -B $(BUILD_DIR) $(CMAKE_GEN) $(CMAKE_FLAGS)

$(BUILD_DIR)/CMakeCache.txt: ensure-deps
	@$(MAKE) configure

.PHONY: build
build: $(BUILD_DIR)/CMakeCache.txt ## Ensure deps, configure (if needed), and build
	cmake --build $(BUILD_DIR) $(BUILD_OPTS)

.PHONY: universal
universal: ## Build fat deps (if needed) and a universal .app
	./scripts/build-universal.sh $(BUILD_DIR)

.PHONY: install
install: build ## Install / finalize the .app bundle
	cmake --install $(BUILD_DIR)

.PHONY: clean
clean: ## Remove BUILD_DIR
	rm -rf $(BUILD_DIR)

.PHONY: distclean
distclean: clean ## Remove BUILD_DIR and deps/
	rm -rf deps

.PHONY: test
test: build ## Build and run CTest
	cd $(BUILD_DIR) && ctest --output-on-failure $(if $(JOBS),-j$(JOBS),)

.PHONY: coverage
coverage: ## Clean rebuild with coverage, run tests, write llvm-cov reports
	@$(MAKE) clean
	@$(MAKE) COVERAGE=ON build test
	./scripts/coverage-report.sh $(BUILD_DIR)

.PHONY: format
format: ## clang-format -i on src/ and tests/
	@command -v clang-format >/dev/null || \
	  { echo "clang-format not in PATH"; exit 1; }
	find src tests -type f \( -name '*.c' -o -name '*.h' -o -name '*.m' \) \
	  -print0 | xargs -0 clang-format -i

# Enforce style on actively maintained units + tests. Legacy mac.m /
# ScreenCapturer.m keep hand-aligned tables; format them only via `make format`.
.PHONY: format-check
format-check: ## clang-format --dry-run on maintained sources + tests
	@command -v clang-format >/dev/null || \
	  { echo "clang-format not in PATH"; exit 1; }
	@ok=0; \
	for f in src/cert_manager.c src/cert_manager.h src/vencrypt.c src/vencrypt.h \
	         $$(find tests -type f \( -name '*.c' -o -name '*.h' -o -name '*.m' \) 2>/dev/null); do \
	  clang-format --dry-run --Werror "$$f" || ok=1; \
	done; \
	exit $$ok

.PHONY: tidy
tidy: $(BUILD_DIR)/CMakeCache.txt ## Run clang-tidy via compile_commands.json
	./scripts/run-clang-tidy.sh $(BUILD_DIR)

.PHONY: launchd-load
launchd-load: ## Install and load the LaunchAgent
	./scripts/launchd.sh load

.PHONY: launchd-unload
launchd-unload: ## Unload the LaunchAgent
	./scripts/launchd.sh unload

.PHONY: launchd-status
launchd-status: ## Print LaunchAgent status
	./scripts/launchd.sh status
