# Thin ergonomic wrapper over CMake.
# Usage: make [TARGET]  [BUILD_DIR=build] [GENERATOR=Ninja]
#
# Examples:
#   make                 # configure (if needed) + build
#   make GENERATOR=Ninja
#   make test
#   make coverage
#   make format
#   make tidy
#   make launchd-load

BUILD_DIR  ?= build
GENERATOR  ?=
PREFIX     ?=
UNIVERSAL  ?= OFF
COVERAGE   ?= OFF
JOBS       ?=

CMAKE_FLAGS := -DMACVNC_UNIVERSAL=$(UNIVERSAL) -DMACVNC_ENABLE_COVERAGE=$(COVERAGE)
ifneq ($(PREFIX),)
  CMAKE_FLAGS += -DCMAKE_PREFIX_PATH=$(PREFIX)
endif

CMAKE_GEN :=
ifneq ($(GENERATOR),)
  CMAKE_GEN := -G "$(GENERATOR)"
endif

BUILD_OPTS :=
ifneq ($(JOBS),)
  BUILD_OPTS += -j$(JOBS)
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
	@printf "  %-18s %s\n" "JOBS" "$(JOBS)"

.PHONY: all
all: build ## Configure (if needed) and build

.PHONY: configure
configure: ## Run cmake configure into BUILD_DIR
	cmake -S . -B $(BUILD_DIR) $(CMAKE_GEN) $(CMAKE_FLAGS)

$(BUILD_DIR)/CMakeCache.txt:
	@$(MAKE) configure

.PHONY: build
build: $(BUILD_DIR)/CMakeCache.txt ## Build the project
	cmake --build $(BUILD_DIR) $(BUILD_OPTS)

.PHONY: install
install: build ## Install / finalize the .app bundle
	cmake --install $(BUILD_DIR)

.PHONY: clean
clean: ## Remove BUILD_DIR
	rm -rf $(BUILD_DIR)

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
	  { echo "clang-format not in PATH (try: brew install clang-format)"; exit 1; }
	find src tests -type f \( -name '*.c' -o -name '*.h' -o -name '*.m' \) \
	  -print0 | xargs -0 clang-format -i

# Enforce style on actively maintained units + tests. Legacy mac.m /
# ScreenCapturer.m keep hand-aligned tables; format them only via `make format`.
.PHONY: format-check
format-check: ## clang-format --dry-run on maintained sources + tests
	@command -v clang-format >/dev/null || \
	  { echo "clang-format not in PATH (try: brew install clang-format)"; exit 1; }
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
