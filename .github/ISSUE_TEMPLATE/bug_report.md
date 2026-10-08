---
name: Bug report
about: Something is broken (does not boot, crashes, wrong result)
title: "[bug] "
labels: bug
---

<!-- Thank you. Please fill in what you can; partial reports are still useful. -->

**Orion-X version**
`cat /etc/orionx-version` on the deck, or the release tag you downloaded (e.g. v2.2.0-beta):

**How you made the stick**
- [ ] orionx-imager (GUI / CLI)
- [ ] dd (macOS / Linux)
- [ ] Rufus / balenaEtcher (Windows)
- [ ] Other:

**Machine you booted**
Make/model, CPU, RAM, UEFI or Legacy BIOS, Secure Boot on/off:

**What you did**
Step by step:

**What you expected**

**What happened instead**
Exact error text, or a photo of the screen for boot problems:

**Diagnostics (if the desktop came up)**
Attach `orionx-diag --json` output, or paste `systemctl --failed` and `journalctl -b -p err` if `orionx-diag` is missing (known beta defect). Remove anything you consider sensitive.
