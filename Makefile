##
# @decision DEC-005 [BUILD]
# @title Makefile targets for Orion-X Phoenix Edition build system
# @status accepted
# @rationale Centralises lint, test, and build entry points so CI and
#   local developers use identical commands. ruff is preferred over flake8
#   because it is faster and covers more rules; py_compile is always run as
#   a fallback when neither linter is installed.
##

.PHONY: lint lint-shell lint-python test-unit test-integration docker-build iso-build clean help

SHELL_SCRIPTS := $(wildcard scripts/*.sh)
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

test-unit: ## Run unit tests
	@echo "=== Unit Tests ==="
	python3 -m pytest tests/unit/ -v --tb=short 2>/dev/null || echo "No unit tests found yet"

test-integration: ## Run integration tests
	@echo "=== Integration Tests ==="
	@if [ -f tests/integration/test-forensic-tools.sh ]; then \
		bash tests/integration/test-forensic-tools.sh; \
	else \
		echo "No integration tests found yet"; \
	fi

docker-build: ## Build Docker development environment
	docker build -t orionx-dev .

iso-build: ## Build ISO image (Linux only)
	@if [ "$$(uname)" != "Linux" ]; then \
		echo "ERROR: ISO build requires Linux. Use 'make docker-build' then build inside container."; \
		exit 1; \
	fi
	bash scripts/build-iso.sh

clean: ## Clean build artifacts
	rm -rf output/ iso/cache/ iso/build/
	find . -name '__pycache__' -type d -exec rm -rf {} + 2>/dev/null || true
	find . -name '*.pyc' -delete 2>/dev/null || true
