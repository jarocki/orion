# Support for Orion-X Phoenix Edition

Orion-X is an open-source project maintained by volunteers. Support is
best-effort, through the GitHub issue tracker. **v2.2.0 is a beta**: reports of
anything confusing, wrong or broken are exactly what we want.

## Before you ask

1. **Read the section of the [User Guide](User_Guide.md) for what you are doing** —
   the Troubleshooting section (§16) covers the most common failures.
2. **Check the [release notes](https://github.com/jarocki/orion/releases)** for
   known limitations of your version.
3. **Search [existing issues](https://github.com/jarocki/orion/issues?q=is%3Aissue)** —
   someone may have hit the same thing.

## Common issues — quick answers

| Symptom | Try |
|---|---|
| The stick does not appear in the boot menu / "Invalid signature" | Turn **Secure Boot off** in firmware; make sure USB boot is allowed; try another USB port (USB-2 ports are the most reliable). |
| Hash check fails after reassembling the parts | You are missing a part or have one twice. `SHA256SUMS` lists every part — check each one; re-download only the part whose hash differs. |
| Black screen after the boot menu | Wait 60 s (slow USB sticks). If still black, reboot and pick **Orion-X Live (failsafe)**. |
| Boot seems stuck with a text banner | That is the **first-boot wizard** waiting on tty1 ("the boot has PAUSED — your input is needed"). Answer the prompts, or wait 120 s per prompt for the defaults. |
| No Wi-Fi networks | Your adapter may need firmware not on the image. Use a cable, or a USB Wi-Fi adapter with in-kernel drivers. `nmcli device` shows what was detected. |
| Nebula AI shows "down" or "integrity FAIL" | `systemctl status nebula-integrity-check nebula-runtime` in a terminal. A FAIL means the model file does not match its checksum — re-write the stick from a verified ISO. |
| Something worked on the reference laptop but not on yours | Please file a bug — hardware coverage is exactly what the beta needs. |

## Reporting a bug or giving beta feedback

Use the templates at **https://github.com/jarocki/orion/issues/new/choose**:

- **Bug report** — something is broken.
- **Beta feedback** — something is confusing, unclear, or could be better; no
  need for it to be "broken".

What helps most (the templates ask for it):

- Orion-X version: `cat /etc/orionx-version` on the deck, or the release tag you downloaded.
- How you made the stick (imager / dd / Rufus) and the machine you booted (make, model, UEFI or BIOS).
- What you did, what you expected, what happened — the exact text of any error.
- For boot problems: a photo of the screen is fine.
- For anything after boot: the output of `orionx-diag --json` (see below).

### Getting `orionx-diag` output off a live system

The live system forgets everything at shutdown, so save the report to
something external before you reboot:

```bash
orionx-diag --json > /tmp/orionx-diag.json      # or without --json for a readable version
# then copy /tmp/orionx-diag.json to a second USB stick, a network share,
# or paste it into the issue.
```

`orionx-diag` reports package, file, service and integrity checks. It does
**not** include your files, captured traffic, chat messages or passwords, but it
does include the hostname and network interface names — remove anything you
consider sensitive before posting. (`orionx-diag` is missing from the
v2.2.0-beta image; that is a known beta defect and is fixed for the next build.
Until then, `systemctl --failed` and `journalctl -b -p err` are the next best
things to include.)

## What Orion-X does and does not do with your data

- **Nothing is sent anywhere automatically.** Nebula AI runs on the stick and
  listens only on the deck itself; there is no telemetry, no update check, no
  crash reporter.
- **Network use happens only when you ask for it:** joining a Wi-Fi network,
  joining a mesh, running an online lookup, uploading to a vault you configured.
  Plugging in a cable will bring up the wired connection (DHCP) so the tools
  can work — unplug it if you want to be sure the deck stays offline.
- **The internal disk of the computer is not touched** unless you mount or image it.

## Commercial support

There is no commercial support offering at this time. For consulting or
training enquiries, open a GitHub Discussion or an issue and we will respond.
