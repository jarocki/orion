# Orion-X Phoenix Edition v2.0.0-dev

Welcome to Orion-X Phoenix Edition! This toolkit is a bootable cybersecurity platform that lets you investigate cyber incidents securely. Simply insert the USB into a target machine, boot into Orion-X, and begin analyzing memory and network traffic within minutes.

## Overview

Orion-X Phoenix Edition v2.0.0-dev is a fully operational, bootable cybersecurity toolkit designed for incident response and digital forensics. It provides a hardened Linux-based live environment with an emphasis on security, privacy, and collaboration.

Key features:
- Bootable media with hardened Linux environment
- Secure boot and full RAM disk encryption
- Matrix for secure team communication
- WireGuard VPN for secure connectivity
- Forensic tools for memory acquisition, disk imaging, network analysis
- Sample data for training and testing
- Phoenix-themed custom interface

## Quick Start

1. Build the ISO (see `Makefile` targets)
2. Create a bootable USB drive:
   ```
   sudo dd if=orionx-phoenix-edition-v2.0.0-dev.iso of=/dev/sdX bs=4M status=progress
   ```
3. Boot from the USB drive (you may need to change BIOS/UEFI settings)
4. Follow on-screen instructions to set up your environment

There are no preset passwords - you will be prompted to create secure credentials on first boot.

## Development

```
make lint       # Run shellcheck + py_compile checks
make test-unit  # Run unit tests (Phase 2 will populate these)
make clean      # Remove build artefacts
```

See `.github/workflows/lint.yml` for the CI configuration.

## Documentation

For detailed usage instructions, please see:
- [User Guide](docs/User_Guide.md) - Comprehensive instructions for using Orion-X
- [Development Checklist](docs/DEVELOPMENT_CHECKLIST.md) - For contributors and developers

## License and Attribution

Orion-X Phoenix Edition is distributed under GPL-3.0. This repository includes third-party tools and sample data, each with their own licenses as documented in the [manifest.json](manifest.json) file.

## Support

For issues, questions, or contributions, please see [docs/SUPPORT.md](docs/SUPPORT.md) and [docs/CONTRIBUTING.md](docs/CONTRIBUTING.md).
