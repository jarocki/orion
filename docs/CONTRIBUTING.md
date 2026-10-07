# Contributing to Orion-X Phoenix Edition

Thank you for your interest in contributing to Orion-X Phoenix Edition! This document provides guidelines and instructions for contributing to the project.

## Code of Conduct

The project does not yet have a separate Code of Conduct document. The expectation is simple: be respectful of other contributors, argue about evidence rather than people, and keep the environment one that a newcomer would want to join.

## How to Contribute

### Reporting Bugs

If you find a bug in Orion-X, please report it by creating an issue in our issue tracker. Include the following information:

- A clear and descriptive title
- Steps to reproduce the bug
- Expected behavior
- Actual behavior
- Screenshots (if applicable)
- Environment information (OS, hardware, etc.)

### Suggesting Enhancements

We welcome suggestions for enhancements. Please create an issue with:

- A clear and descriptive title
- A detailed description of the proposed enhancement
- Reasoning behind the enhancement (use cases)
- Any relevant examples or mockups

### Pull Requests

1. Fork the repository
2. Create a new branch for your feature or bugfix
3. Make your changes
4. Ensure your code follows our coding standards
5. Run tests if applicable
6. Submit a pull request

Please follow the [Development Checklist](DEVELOPMENT_CHECKLIST.md) when making changes.

## Development Setup

To set up a development environment:

1. Clone the repository
2. Install the tools the checks use: `bash`, `python3` (3.13 to match the image), `shellcheck` and `ruff` for `make lint`; Docker for `make iso-build` on macOS (see README.md, *Development*)
3. Familiarize yourself with the ISO build system in the `iso/` directory (lower-case — `scripts/build-iso.sh` refuses an upper-case `ISO/` checkout) and its entry point `scripts/build-iso.sh`

## Testing

Before submitting a pull request, please test your changes thoroughly:

- For script changes, ensure they run correctly on various Linux distributions
- For ISO build changes, build a test ISO and verify it boots correctly
- For documentation changes, verify clarity and accuracy

## Coding Standards

- Follow consistent indentation (spaces, not tabs)
- Use meaningful variable and function names
- Comment complex code sections
- Include proper error handling
- Document all user-facing functionality

## License

By contributing to Orion-X Phoenix Edition, you agree that your contributions will be licensed under the project's GPL-3.0 license.

## Questions

If you have any questions about contributing, please create an issue tagged with "question" or contact the maintainers directly.

Thank you for helping improve Orion-X Phoenix Edition!

## Coding norms

- **No JetBrains software** — per DEC-PHASE11-013, Orion-X does not include any
  JetBrains-branded tools or fonts. Use **Hack**, which is the only monospace
  font the image ships. Iosevka is *not* shipped and is not scheduled: there is
  no `fonts-iosevka` candidate in Debian 13 (trixie), so it cannot be pulled
  from the archive the ISO builds against (#85). Do not reference Iosevka in
  themes, `terminalrc`, `xsettings.xml`, or greeter config.
- **Offline-tolerant** — every runtime path must fail cleanly (loud + non-zero
  exit) when the network is unreachable. See `orionx-freshen-yara`,
  `orionx-freshen-suricata`, and `install-*.sh` for reference patterns.
- **Single authority** — every operational fact has one owner module. Adding
  a new mechanism means removing the one it replaces, not shipping both.
