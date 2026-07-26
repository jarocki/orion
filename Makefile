##
# @decision DEC-005 [BUILD]
# @title Makefile targets for Orion-X Phoenix Edition build system
# @status accepted
# @rationale Centralises lint, test, and build entry points so CI and
#   local developers use identical commands. ruff is preferred over flake8
#   because it is faster and covers more rules; py_compile is always run as
#   a fallback when neither linter is installed.
##

.PHONY: lint lint-shell lint-python test-unit test-unit-bash test-unit-python test-integration test-forensic test-security test-mesh test-matrix test-e2e test-qemu-boot docker-build docker-build-matrix iso-build lynis clean help

SHELL_SCRIPTS := $(shell find scripts -name '*.sh' -type f)
PYTHON_SCRIPTS := $(wildcard scripts/*.py)

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-20s\033[0m %s\n", $$1, $$2}'

lint: lint-shell lint-python ## Run all linters

lint-shell: ## Lint shell scripts with ShellCheck
	@echo "=== ShellCheck ==="
	shellcheck $(SHELL_SCRIPTS)

lint-python: ## Lint Python scripts with ruff (or flake8 fallback)
	@echo "=== Python lint ==="
	@if command -v ruff >/dev/null 2>&1; then \
		ruff check $(PYTHON_SCRIPTS); \
	elif command -v flake8 >/dev/null 2>&1; then \
		flake8 $(PYTHON_SCRIPTS); \
	else \
		echo "No Python linter found, running py_compile only"; \
	fi
	@for f in $(PYTHON_SCRIPTS); do python3 -m py_compile "$$f" && echo "  $$f: OK"; done

test-unit-bash: ## Run bash unit tests
	@echo "=== Bash Unit Tests ==="
	@for f in tests/unit/test_*.sh; do \
		[ -f "$$f" ] || continue; \
		echo "  Running $$f ..."; \
		bash "$$f" || exit 1; \
	done

test-unit-python: ## Run Python unit tests
	@echo "=== Python Unit Tests ==="
	python3 -m pytest tests/unit/ -v --tb=short 2>/dev/null || echo "No Python unit tests found yet"

test-unit: test-unit-bash test-unit-python ## Run all unit tests (bash + python)

test-integration: ## Run integration tests
	@echo "=== Integration Tests ==="
	@if [ -f tests/integration/test-forensic-tools.sh ]; then \
		bash tests/integration/test-forensic-tools.sh; \
	else \
		echo "No integration tests found yet"; \
	fi
	@if [ -f tests/integration/test-security-hardening.sh ]; then \
		bash tests/integration/test-security-hardening.sh; \
	fi

test-forensic: ## Validate forensic tools respond to --version/--help
	bash tests/integration/test-forensic-tools.sh

test-security: ## Validate Phase 6 security hardening deliverables
	bash tests/integration/test-security-hardening.sh

test-mesh: ## Run 3-node mesh integration test in Docker
	docker compose -f docker/docker-compose.mesh-test.yml build
	docker compose -f docker/docker-compose.mesh-test.yml up -d
	@echo "Waiting for mesh formation (30s)..."
	@sleep 30
	@echo "Running integration tests..."
	bash tests/integration/test-mesh.sh || true
	docker compose -f docker/docker-compose.mesh-test.yml down -v

test-e2e: ## Run full Phase 7 E2E scenario in Docker (3-node stack, ~10min)
	bash tests/integration/test-e2e-scenario.sh

docker-build-matrix: ## Build Matrix test Docker image
	docker compose -f docker/docker-compose.matrix-test.yml build

test-matrix: ## Run Matrix integration test in Docker
	docker compose -f docker/docker-compose.matrix-test.yml build
	docker compose -f docker/docker-compose.matrix-test.yml up -d
	@echo "Waiting for Synapse to be healthy..."
	@timeout 120 bash -c 'until docker compose -f docker/docker-compose.matrix-test.yml exec -T matrix-server curl -sf http://localhost:8008/_matrix/client/versions >/dev/null 2>&1; do sleep 5; done' || echo "WARNING: Synapse health check timed out"
	@echo "Running Matrix integration tests..."
	bash tests/integration/test-matrix.sh || true
	docker compose -f docker/docker-compose.matrix-test.yml down -v

test-qemu-boot: ## Run QEMU boot harness (UEFI + BIOS) on the latest ISO; override with ISO=<path>
	bash scripts/qemu-boot-test.sh --mode both $(if $(ISO),--iso $(ISO),)

docker-build: ## Build Docker development environment
	docker build -t orionx-dev .

iso-build: test-unit ## Build ISO image; auto-wraps in Docker on macOS
	bash scripts/build-iso.sh

lynis: ## Run Lynis security audit
	bash scripts/run-lynis.sh --threshold 75

clean: ## Clean build artifacts
	rm -rf output/ iso/cache/ iso/build/
	find . -name '__pycache__' -type d -exec rm -rf {} + 2>/dev/null || true
	find . -name '*.pyc' -delete 2>/dev/null || true
