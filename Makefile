# Orion-X Phoenix Edition — Build orchestrator
# Phase 2 will expand these targets with ISO build, Docker, and full test suite.

.PHONY: lint test-unit clean

lint:
	shellcheck scripts/*.sh
	python3 -m py_compile scripts/artifact-analyzer.py
	python3 -m py_compile scripts/storyboard-gen.py

test-unit:
	@echo "No unit tests yet — Phase 2 will add them"

clean:
	rm -rf output/ iso/cache/ iso/build/
