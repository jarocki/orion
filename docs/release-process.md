# Orion-X Release Process — Operator Runbook

Tag-triggered release pipeline for Orion-X Phoenix Edition. This document is
the operator-facing companion to `.github/workflows/release.yml` (built per
DEC-PHASE8-002) and the `scripts/release/extract-release-notes.sh` helper.

The pipeline is intentionally split into two halves:

1. **Automated half (CI)** — build, checksum, sign, upload a **DRAFT** GitHub
   Release on tag push.
2. **Manual half (operator)** — review the draft, verify artifacts, and flip
   `DRAFT → Published` (the W8-7 `approve` gate, per DEC-PHASE7-005).

The `DRAFT` boundary is non-negotiable. CI never publishes a release on its own.

---

## 1. Prerequisites

Before tagging:

- **Phase 7 attestation (W7-7)** is complete for any final `v2.0.0` tag. Release
  candidate tags (`v2.1.0-rcN`) MAY be cut before W7-7 lands; final releases MUST
  NOT.
- **GPG signing key** is provisioned as repository secrets:
  - `secrets.GPG_PRIVATE_KEY` — ASCII-armored private key
  - `secrets.GPG_PASSPHRASE` — passphrase for the key

  Until these are provisioned, the GPG step runs with `continue-on-error: true`
  and the DRAFT release is produced **without** `.asc` signature files. The
  pipeline does not fail; the operator must either provision the key and
  re-run, or attach signatures manually before publishing.
- **`develop` is at the head you intend to release.** All three CI workflows
  (`lint.yml`, `e2e-test.yml`, `qemu-test.yml`) are green on that head.
- **`CHANGELOG.md` is updated** with a section for the version you are about
  to tag. The section heading must match one of:
  - `## [2.0.0-rc1] — <date or status>`
  - `## [v2.1.0-rc1] — <date or status>`

  `extract-release-notes.sh` matches both forms. If no section is found, the
  release body falls back to `"See CHANGELOG.md for full release history."`

---

## 2. Cutting a release candidate (`v2.1.0-rcN`)

From a clean checkout of `develop` at the head you intend to release:

```bash
git fetch origin
git checkout develop
git pull --ff-only origin develop

# Confirm head matches what you reviewed
git log -1 --oneline

# Annotated tag — the message is what `git describe` will surface.
git tag -a v2.1.0-rc1 -m "Orion-X Phoenix Edition v2.1.0-rc1"

# Push the tag — this fires release.yml.
git push origin v2.1.0-rc1
```

Tag push triggers `.github/workflows/release.yml`. The workflow auto-flags
`prerelease: true` when the tag contains `-rc`.

---

## 3. What CI does (release.yml, 8 steps)

The workflow runs on `ubuntu-latest` with a 60-minute timeout (mirroring
`qemu-test.yml`'s ISO build budget). Source of truth: `.github/workflows/release.yml`.

1. **Checkout repository** — `actions/checkout@v4` with `fetch-depth: 0` so
   `CHANGELOG.md` and git history are always available, even on shallow tag
   triggers.
2. **Build ISO inside `debian:bullseye-slim`** — same Docker pattern as
   `qemu-test.yml` (W7-1, issue #25). live-build detects the host distro, so
   we run privileged inside Debian Bullseye to ensure it bootstraps from
   `deb.debian.org/bullseye` rather than the Ubuntu runner's apt sources.
   Output goes to `output/*.iso`; build log is captured to
   `tmp/release-build-iso.log`. Workspace ownership is `chown`ed back to the
   runner UID afterward.
3. **Verify ISO artifact** — hard-fails the run if `output/` contains zero
   ISO files. No silent success.
4. **Generate checksums** — `sha256sum` and `sha512sum` over each
   `output/*.iso`, written to `output/SHA256SUMS` and `output/SHA512SUMS`.
5. **GPG sign (best-effort)** — imports the key via
   `crazy-max/ghaction-import-gpg@v6`, then produces detached, armored
   signatures:
   - `output/<iso>.asc` for each ISO
   - `output/SHA256SUMS.asc`
   - `output/SHA512SUMS.asc`

   `continue-on-error: true` on both import and sign steps. If the key is
   missing or import fails, the run sets `GPG_SIGNED=false` and proceeds.
6. **Extract release notes** — runs `scripts/release/extract-release-notes.sh
   "${GITHUB_REF_NAME}"`, which parses `CHANGELOG.md` for the matching
   `## [<version>]` section and writes it to `tmp/release-notes.md`. Falls
   back to a static "See CHANGELOG.md" line if no section matches.
7. **Create DRAFT GitHub Release** via `softprops/action-gh-release@v2`:
   - `draft: true` — **always**, regardless of tag shape.
   - `prerelease: true` — auto-flagged when tag contains `-rc`.
   - `body_path: tmp/release-notes.md`
   - `files:` glob uploads `output/*.iso`, both `SHA*SUMS`, and any `*.asc`
     that exist. `fail_on_unmatched_files: false` so a skipped GPG step does
     not break the release.
8. **Upload artifacts to Actions + emit summary** — `actions/upload-artifact@v4`
   always runs (`if: always()`), bundling the ISO, checksums, signatures, the
   build log, and the release notes under
   `release-artifacts-<run_id>`. A final shell step prints a Release Pipeline
   Summary with the tag, GPG signing state, and `output/` listing.

Expected wall-clock: ISO build ~10–15 min, total run ~15–20 min.

---

## 4. Publishing the release (W8-7 operator approve gate)

Once the workflow completes successfully, the DRAFT exists but is **not
visible to the public**. The operator owns the publish flip.

### 4.1. Locate the draft

- GitHub UI: **Repository → Releases** → the draft appears at the top, tagged
  with the version and a `Draft` badge.
- CLI: `gh release view v2.1.0-rc1 --json isDraft,assets`

### 4.2. Verify the artifacts

Download the draft assets (`gh release download v2.1.0-rc1 -D /tmp/orion-rc1`
or via the UI) and run, from the download directory:

```bash
# Checksum verification — both must report "OK" for every artifact line.
sha256sum -c SHA256SUMS
sha512sum -c SHA512SUMS

# GPG signature verification (only if .asc files are present)
gpg --verify SHA256SUMS.asc SHA256SUMS
gpg --verify SHA512SUMS.asc SHA512SUMS
# And for each ISO:
gpg --verify orion-x-<version>.iso.asc orion-x-<version>.iso
```

`gpg --verify` exits 0 and prints `Good signature from "..."` on success.
Any other outcome is a stop-the-line event.

If `.asc` files are missing because the GPG key was not provisioned at CI
time, either:
- provision `secrets.GPG_PRIVATE_KEY` / `secrets.GPG_PASSPHRASE` and re-run
  the workflow via `workflow_dispatch`, then upload the new `.asc` files to
  the draft; or
- sign the artifacts locally and attach the resulting `.asc` files via
  `gh release upload v2.1.0-rc1 <files>`.

### 4.3. Final preflight before publish

- Release notes (the rendered Markdown body) match the `CHANGELOG.md`
  section.
- For a final `v2.0.0` tag: **W7-7 attestation is complete.** Do not publish
  a final release without it.
- Asset list contains, at minimum: ISO, `SHA256SUMS`, `SHA512SUMS`. If GPG
  signing was expected, `.asc` siblings for each.

### 4.4. Flip DRAFT → Published

UI: open the draft, click **Publish release**.

CLI: `gh release edit v2.1.0-rc1 --draft=false`

This is the W8-7 `approve` gate. Once flipped, the release is public.

---

## 5. Promotion: `v2.1.0-rcN` → `v2.0.0` final

When an RC has soaked sufficiently and W7-7 attestation is complete:

1. **Update CHANGELOG.md** — rename the `## [v2.1.0-rc1]` section to
   `## [v2.0.0] — <release date>` (or add a new `## [v2.0.0]` section that
   supersedes the rc entry). The new section is what `extract-release-notes.sh`
   will return for the `v2.0.0` tag.
2. **Bump version literals** — same shape as W8-1 version-bump touchpoints:
   - `Dockerfile` (image labels)
   - `README.md`
   - `docs/User_Guide.md`
   - `scripts/build-iso.sh` (`VERSION=` line)
   - `iso/auto/config` (or equivalent live-build hook)

   Grep for the previous rc string to confirm coverage:
   `git grep -n 'v2.1.0-rc1'`
3. **Land via the canonical chain on `develop`** — planner → guardian
   (provision) → implementer → reviewer → guardian (land). Do not hand-edit
   the bump on `main`. (Sacred Practice #2.)
4. **Tag from the updated `develop` head:**
   ```bash
   git fetch origin
   git checkout develop
   git pull --ff-only origin develop
   git tag -a v2.0.0 -m "Orion-X Phoenix Edition v2.0.0"
   git push origin v2.0.0
   ```
5. **CI produces a DRAFT release.** Repeat Section 4 to verify and publish.
   `prerelease` will be `false` automatically (tag does not contain `-rc`).

---

## 6. Rollback

The rollback path depends on whether the release has been **published**.

### 6.1. Pre-publish (DRAFT still unflipped)

The draft is operator-private; rolling it back is non-destructive:

```bash
gh release delete v2.1.0-rc1            # deletes the draft + uploaded assets
# Note: the underlying git tag is NOT deleted by `release delete`.
```

To also remove the tag (when the tagged commit itself was wrong):

```bash
git tag -d v2.1.0-rc1                   # local
git push origin :refs/tags/v2.1.0-rc1   # remote
```

### 6.2. Post-publish retraction

Retracting a **published** release is destructive — users may have already
downloaded the artifacts, and tools may have cached the tag. Per
DEC-PHASE7-008, retraction is an explicit user-decision boundary:

- Do not delete or rewrite published tags without explicit user approval.
- Prefer **superseding** with a new patch tag plus a release-notes addendum
  that documents the retraction and the fix.
- If retraction is unavoidable, the user must adjudicate the destructive git
  action via guardian (per Sacred Practice #8). The orchestrator must not
  self-execute history rewrite or tag deletion on a published release.

---

## 7. Dry-run mode

`release.yml` supports `workflow_dispatch` with a `dry_run` boolean input,
for validating pipeline changes without producing a public artifact:

UI: **Actions → Release Pipeline → Run workflow** → set `dry_run: true`.

CLI: `gh workflow run release.yml -f dry_run=true`

Behavior:

- Steps 1–6 run normally (build, verify, checksum, sign, extract notes).
- Step 7 (Create DRAFT GitHub Release) is **skipped** — the `if:` clause
  requires `github.event_name == 'push'` or `github.event.inputs.dry_run ==
  'false'`.
- Step 8 (Upload to Actions) still runs, so all artifacts are downloadable
  from the workflow run page for inspection.

Use a dry run when:
- changing live-build configuration that may affect the ISO contents
- adjusting the GPG signing flow
- verifying `CHANGELOG.md` section parsing for a new version string
- validating runner image or apt mirror changes

---

## 8. Cross-references

- **Code:**
  - `.github/workflows/release.yml` — the pipeline itself
  - `scripts/release/extract-release-notes.sh` — release-notes parser
  - `CHANGELOG.md` — single source of truth for release notes
- **Decisions (see MASTER_PLAN.md → Decision Log):**
  - `DEC-PHASE8-002` — release artifact pipeline rationale (Docker-in-CI for
    live-build, DRAFT-mode mandatory, GPG `continue-on-error` until key
    provisioned)
  - `DEC-PHASE7-005` — `approve` gate convention (operator owns publish flip)
  - `DEC-PHASE7-008` — destructive git actions require explicit user
    adjudication (applies to published-release retraction)
- **Related work items:**
  - W8-4 / W8-5 — release pipeline build-out
  - W8-7 — operator publish gate
  - W7-7 — final-release attestation prerequisite
- **Followups:**
  - Issue #41 — backend decode hygiene followup

## 9. Phase 11 hotfix pattern (W11-Nx sub-slices)

When a CI or hardware test reveals a gap in a landed W11-N slice, ship a
sub-slice W11-Nx (where x = b, c, d, ...) rather than a follow-up patch on
the next `--edit` cycle. Examples from the 2026-07-19 arc:

- W11-2 landed the debloat + bootloader single-authority
- W11-2b hotfixed a shellcheck SC2001 in the generator
- W11-2c fixed 4 CI content-presence assertions
- W11-2d rewrote a Python import test to be structural (not runtime)
- W11-2e pinned the Qwen SHA256 (moved from TBD sentinel)
- W11-2f disabled XFCE auto-lock

Each sub-slice: full planner -> implementer -> reviewer -> guardian:land chain.
Keeps the mainline W11-N Evaluation Contract stable; hotfix items don't drift
the DEC.
