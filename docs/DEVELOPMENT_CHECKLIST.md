# Orion-X Phoenix Edition Development Checklist

This checklist outlines the tasks and best practices to follow when modifying or releasing Orion-X. It ensures quality, security, and transparency are maintained throughout the development process.

## Before Committing Code

- [ ] Code follows our style guide (consistent indentation, meaningful variable names)
- [ ] All scripts have proper error handling and logging
- [ ] Scripts include help/usage information when run with `-h` or `--help`
- [ ] Python code is compatible with Python 3.6+
- [ ] Bash scripts use `#!/bin/bash` shebang and include `set -e` for error handling
- [ ] No debugging statements or commented-out code blocks remain
- [ ] All user-facing documentation uses clear language (high school reading level)
- [ ] New features are documented in the appropriate files

## Security Checks

- [ ] Run `run-lynis.sh` and review the Lynis audit report – address any high or medium warnings
- [ ] Verify no hard-coded credentials exist in any file (search for keywords like "password", "token", "secret", "key")
- [ ] All configuration files with credentials use template files (.template extension) as examples only
- [ ] Sensitive operations are properly logged but do not log credentials or keys
- [ ] Input validation is performed on all user inputs
- [ ] File permissions are appropriate (e.g., config files are not world-readable)
- [ ] Network services have proper authentication and encryption

## Before Release

- [ ] Update version numbers in all appropriate files
- [ ] Update `RELEASE_NOTES.md` with changes since the last version
- [ ] Update `manifest.json` with any new components, dependencies, or sample data
- [ ] Verify all third-party tools and data are properly attributed and licensed
- [ ] Test build-iso.sh on a clean system to verify build reproducibility
- [ ] Test installation on both UEFI and BIOS systems
- [ ] Test all core features (VPN, Matrix, forensic tools) with sample data
- [ ] Verify all documentation matches the actual functionality
- [ ] Run a final Lynis audit and address any remaining security issues

## Adding New Tools or Samples

- [ ] For new tools, verify they are compatible with our license policy
- [ ] For new sample data, ensure proper attribution and permissions
- [ ] Add entries to manifest.json for all new third-party components
- [ ] Document the new tool or sample in the User Guide
- [ ] Create or update READMEs in appropriate directories
- [ ] Test that new tools work properly with the forensic workflow

## Adding New Theme Assets

- [ ] Ensure all image assets are properly sized and optimized
- [ ] Verify theme works across supported desktop environments
- [ ] Test terminal themes in different terminal emulators
- [ ] Add attribution for any external assets or inspiration
- [ ] Update toggle-theme.sh to support the new assets

## Release Process

- [ ] Tag the release in git using semantic versioning (e.g., v1.5.5)
- [ ] Generate SHA-256 hash of the release package
- [ ] Update the download link and hash in the README
- [ ] Create a release entry on GitHub/GitLab
- [ ] Archive the source code and build artifacts

## Post-Release

- [ ] Notify the team of the new release
- [ ] Monitor for any reported issues
- [ ] Create tickets for any known issues or planned features for the next release
- [ ] Update roadmap as needed

---

This checklist helps standardize the development process and is especially useful for open-source contributors who want to contribute code. Before submitting a pull request or cutting a new release, please go through the relevant sections of this checklist.

## Phase 11 slice cadence

Each Phase 11 slice follows: planner (Detail Plan + EC in `MASTER_PLAN.md`) ->
guardian:provision (worktree + lease) -> implementer -> reviewer ->
guardian:land (merge + push). Hotfixes use the W11-Nx pattern (see
`docs/release-process.md`). MASTER_PLAN.md carries the authoritative
Evaluation Contract for every landed slice.
