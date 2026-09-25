# Thin ergonomic wrapper over CMake.
#
# Common flows (Mac Studio → Intel iMac):
#   make deps            # fat OpenSSL + LibVNCServer (both arches)
#   make universal       # → build-universal/macVNC.app
#   make dist            # → dist/*.pkg + dist/*.dmg
#   make scrub           # wipe build trees, deps, and dist artifacts
#
# Local native testing:
#   make UNIVERSAL=OFF build test
#
# Other: make help

BUILD_DIR      ?= build
DIST_BUILD_DIR ?= build-universal
DIST_DIR       ?= dist
GENERATOR      ?=
PREFIX         ?=
UNIVERSAL      ?= ON
COVERAGE       ?= OFF
JOBS           ?=
DEPS_ARCH      ?=
DIST_TAG       ?=
DIST_RELEASE   ?= 0
DIST_FORCE     ?= 0

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
	@printf "  %-18s %s\n" "DIST_BUILD_DIR" "$(DIST_BUILD_DIR)"
	@printf "  %-18s %s\n" "DIST_DIR" "$(DIST_DIR)"
	@printf "  %-18s %s\n" "GENERATOR" "$(GENERATOR)"
	@printf "  %-18s %s\n" "UNIVERSAL" "$(UNIVERSAL)"
	@printf "  %-18s %s\n" "COVERAGE" "$(COVERAGE)"
	@printf "  %-18s %s\n" "PREFIX" "$(PREFIX)"
	@printf "  %-18s %s\n" "DEPS_ARCH" "$(DEPS_ARCH)"
	@printf "  %-18s %s\n" "JOBS" "$(JOBS)"
	@printf "  %-18s %s\n" "DIST_TAG" "$(DIST_TAG)"
	@printf "  %-18s %s\n" "DIST_RELEASE" "$(DIST_RELEASE)"
	@printf "  %-18s %s\n" "DIST_FORCE" "$(DIST_FORCE)"

#
# Dependencies
#
.PHONY: deps
deps: ## Build OpenSSL + LibVNCServer from source (omit DEPS_ARCH for fat libs)
	./scripts/build-deps.sh $(DEPS_ARGS)

# Stamp / library that configure requires. UNIVERSAL=ON needs fat libs;
# UNIVERSAL=OFF can use a single host-arch prefix (faster).
DEPS_UNIVERSAL_LIB := deps/prefix/universal/lib/libvncserver.a
DEPS_HOST_LIB := deps/prefix/$(shell uname -m)/lib/libvncserver.a

.PHONY: ensure-deps
ensure-deps: ## Ensure deps exist (universal builds always refresh via build-deps stamps)
ifeq ($(UNIVERSAL),ON)
	@# Always run build-deps (no --arch): cheap when stamps match, rebuilds when
	@# LibVNC patch rev / OpenSSL version stamps change — required for make dist.
	@if [[ -n "$(DEPS_ARCH)" ]]; then \
	  echo "note: UNIVERSAL=ON ignores DEPS_ARCH=$(DEPS_ARCH); building both arches"; \
	fi
	./scripts/build-deps.sh
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

#
# App build (native or fat according to UNIVERSAL → BUILD_DIR)
#
.PHONY: all
all: build ## Configure (if needed) and build into BUILD_DIR

.PHONY: configure
configure: ensure-deps ## cmake configure into BUILD_DIR
	env -u PKG_CONFIG_PATH -u LDFLAGS -u CPPFLAGS \
	  cmake -S . -B $(BUILD_DIR) $(CMAKE_GEN) $(CMAKE_FLAGS)

$(BUILD_DIR)/CMakeCache.txt: ensure-deps
	@$(MAKE) configure

.PHONY: build
build: $(BUILD_DIR)/CMakeCache.txt ## Build into BUILD_DIR
	cmake --build $(BUILD_DIR) $(BUILD_OPTS)

.PHONY: install
install: build ## Finalize .app bundle in BUILD_DIR (cmake --install)
	cmake --install $(BUILD_DIR)

#
# Universal / distribution (always DIST_BUILD_DIR = build-universal)
#
.PHONY: universal
universal: ## Fat .app → DIST_BUILD_DIR (Studio→Intel copy target)
	./scripts/build-universal.sh $(DIST_BUILD_DIR)

.PHONY: pkg
pkg: universal ## Universal product .pkg only
	DIST_DIR=$(DIST_DIR) DIST_REQUIRE_UNIVERSAL=1 DIST_FORMAT=pkg \
	  DIST_SKIP_INSTALL=1 DIST_TAG=$(DIST_TAG) DIST_RELEASE=$(DIST_RELEASE) \
	  DIST_FORCE=$(DIST_FORCE) ./scripts/dist.sh $(DIST_BUILD_DIR)

.PHONY: dist
dist: universal ## Universal .pkg inside .dmg (macOS 15 Intel + Apple Silicon)
	DIST_DIR=$(DIST_DIR) DIST_REQUIRE_UNIVERSAL=1 DIST_SKIP_INSTALL=1 \
	  DIST_TAG=$(DIST_TAG) DIST_RELEASE=$(DIST_RELEASE) DIST_FORCE=$(DIST_FORCE) \
	  ./scripts/dist.sh $(DIST_BUILD_DIR)

#
# Clean
#
.PHONY: clean
clean: ## Remove app build trees (BUILD_DIR + DIST_BUILD_DIR)
	rm -rf $(BUILD_DIR) $(DIST_BUILD_DIR)
	rm -f compile_commands.json

.PHONY: distclean
distclean: clean ## clean + remove deps/ (keeps dist/ packages)
	rm -rf deps

.PHONY: scrub
scrub: distclean ## Full wipe: build trees, deps/, and dist/ artifacts
	rm -rf $(DIST_DIR)
	@echo "scrubbed: $(BUILD_DIR)/ $(DIST_BUILD_DIR)/ deps/ $(DIST_DIR)/"

#
# Test / quality
#
.PHONY: test
test: build ## Build and run CTest in BUILD_DIR
	cd $(BUILD_DIR) && ctest --output-on-failure $(if $(JOBS),-j$(JOBS),)

.PHONY: coverage
coverage: ## Clean rebuild with coverage, run tests, write llvm-cov reports
	@$(MAKE) clean
	@$(MAKE) COVERAGE=ON UNIVERSAL=OFF build test
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
	         src/frame_pipeline.c src/frame_pipeline.h src/macvnc_metrics.c src/macvnc_metrics.h \
	         $$(find tests -type f \( -name '*.c' -o -name '*.h' -o -name '*.m' \) 2>/dev/null); do \
	  clang-format --dry-run --Werror "$$f" || ok=1; \
	done; \
	exit $$ok

.PHONY: tidy
tidy: $(BUILD_DIR)/CMakeCache.txt ## clang-tidy via compile_commands.json
	./scripts/run-clang-tidy.sh $(BUILD_DIR)

#
# LaunchAgent helpers
#
.PHONY: launchd-load
launchd-load: ## Install and load the LaunchAgent
	./scripts/launchd.sh load

.PHONY: launchd-unload
launchd-unload: ## Unload the LaunchAgent
	./scripts/launchd.sh unload

.PHONY: launchd-status
launchd-status: ## Print LaunchAgent status
	./scripts/launchd.sh status
