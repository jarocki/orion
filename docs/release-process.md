# Orion-X Release Process — Operator Runbook

Tag-triggered release pipeline for Orion-X Phoenix Edition. This document is
the operator-facing companion to `.github/workflows/release.yml` (built per
DEC-PHASE8-002) and the `scripts/release/extract-release-notes.sh` helper.

The release asset set (split parts, checksums, signatures, reassembly text and
release body) is produced by one script, `scripts/release/stage-split-release.sh`
(DEC-PHASE12-115), which both CI and the manual path call.

The pipeline is intentionally split into two halves:

1. **Automated half (CI)** — build, checksum, sign, upload a **DRAFT** GitHub
   Release on tag push.
2. **Manual half (operator)** — review the draft, verify artifacts, and flip
   `DRAFT → Published` (the W8-7 `approve` gate, per DEC-PHASE7-005).

The `DRAFT` boundary is non-negotiable. CI never publishes a release on its own.

---

## 0. Which path is the authority

Every Trixie-line image is over 2 GiB (v2.2.0-beta 3.09 GB, v2.2.0-rc9
3.13 GB) and GitHub rejects release assets over 2 GiB, so the ISO is always
published as parts. Both paths below publish the same asset set, because both
run `scripts/release/stage-split-release.sh`:

| Path | When | Asset set |
|---|---|---|
| CI draft (§3) → operator verifies and publishes (§4) | Default for a pushed `v*` tag | `*.iso.part-*` (190 MiB), `SHA256SUMS(.asc)`, `SHA512SUMS(.asc)`, `REASSEMBLE.txt`; body = CHANGELOG section + download/verify instructions |
| Manual staging from the build host (§10) | CI cannot build or upload (runner budget, outage), or the ISO was built and gated on the build host | Identical, staged locally and uploaded with `gh` |

Use one path per tag. If both ran, delete the draft you will not publish
(§6.1) so its parts cannot be mixed with the other set, whose ISO hash
differs.

In both cases a human publishes. The `DRAFT` boundary is non-negotiable.

## 1. Prerequisites

Before tagging:

- **The branch is at the head you intend to release** — `release/2.2.0` for
  the v2.2.0 line (merged back to `develop` after the tag). The image is built
  from the tagged commit, or with `ORIONX_VERSION=<tag>` exported, so that the
  baked `/etc/orionx-version` equals the tag (§4.3, §10 step 0). The beta
  shipped as `v2.2.0-trixie-dev9` because this was not enforced.
- **CI on that head:** `lint.yml` and `e2e-test.yml` green. `qemu-test.yml`
  (which, like `release.yml`, now builds in `debian:trixie-slim`) must have
  produced an ISO and passed the content-presence gate and the BIOS+UEFI boot
  test; W7-4-B/W7-5/W7-6 are `continue-on-error` and informative. All three
  workflows trigger on pushes and PRs to `release/**` as well as `develop`
  (DEC-PHASE12-123). For a head that has not been pushed, run the same gates
  locally with `scripts/release/ci-local.sh --e2e --iso <iso> --build-log
  <log>` and quote its summary (and the host tool versions it prints) in the
  release notes. If the runner budget prevents a full run, say so in the
  release notes rather than skipping silently.
- **All documentation fixes have landed** — the ISO bakes `README.md` and
  `docs/` into `/usr/share/doc/orionx/`; the beta carried a pre-beta README.
- **Version literals bumped.** `scripts/build-iso.sh` has no version literal
  (it uses `ORIONX_VERSION` or `git describe`, DEC-PHASE7-002) and
  `iso/auto/config` only a fallback default. The real touchpoints are:
  `README.md` (header, download commands, Known issues), `docs/User_Guide.md`
  (the rendered copy takes its release line from `/etc/orionx-version`; the
  Markdown still names the release in its header and §2), `CHANGELOG.md`,
  `tools/guided-demo/scenes.yaml` and `tools/guided-demo/cinematic/trailer.yaml`
  (`version:` — the demo and trailer are re-cut per release), `docs/orionx-diag.md`,
  `manifest.json`, the `Dockerfile` label, and the release notes. Confirm with
  `git grep -n '<previous tag>'` that only historical references remain, and
  that no `<vX.Y.Z SHA-256 — filled at release>` placeholder is left
  (`git grep -n 'filled at release'` must be empty before the tag).
- **GPG signing key** is provisioned as repository secrets:
  - `secrets.GPG_PRIVATE_KEY` — ASCII-armored private key
  - `secrets.GPG_PASSPHRASE` — passphrase for the key

  The release signing identity is:

  ```
  pub   ed25519 2026-09-28 [SC] [expires: 2027-09-28]
        4CB08BD1D0B3281613DD15DB1DCCDF47FEEDEEEF
  uid   John Jarocki <john@jarocki.org>
  ```

  Publish that fingerprint somewhere a downloader can check it **independently
  of this repository** — a personal site, a keyserver, a social profile. A
  fingerprint that only appears next to the download it authenticates proves
  nothing: whoever could tamper with the release could also edit the
  fingerprint beside it.

  Note the expiry. Renew before 2027-09-28, or signing breaks mid-release.

  **These steps now hard-fail if the key is missing (DEC-PHASE12-026).** They
  previously ran with `continue-on-error: true`, which meant the pipeline
  happily produced a publishable draft with no signatures — and since the key
  was never provisioned, every release it could produce was silently unsigned.
  `SHA256SUMS` served from the same page as the ISO is not an integrity story:
  it proves only that the file matches what that page claims. Anyone who can
  replace the ISO can replace the checksum beside it.

  If the signing step fails, provision the secrets. Do not re-add
  `continue-on-error` to get a release out.
- **`CHANGELOG.md` is updated** with a section for the version you are about
  to tag, including its *Known issues* list. The section heading must match
  one of:
  - `## [2.2.0] — <date or status>`
  - `## [v2.2.0] — <date or status>`

  `extract-release-notes.sh` matches both forms (anything after the closing
  `]` is free text) and ends the section at the next `## ` heading. A missing
  or empty section is an error, not an empty body (DEC-PHASE12-114):
  `build-iso.sh` refuses to build a release-looking version
  (`vX.Y.Z`, `vX.Y.Z-rcN`, `-betaN`, `-alphaN`) without it, and
  `stage-split-release.sh` refuses to stage it. Check before tagging:
  `bash scripts/release/extract-release-notes.sh <tag>`.

---

## 2. Cutting a pre-release (`v2.2.0-beta`, `v2.2.0-rcN`)

From a clean checkout at the head you intend to release:

```bash
git fetch origin
git checkout release/2.2.0
git pull --ff-only origin release/2.2.0

# Confirm head matches what you reviewed
git log -1 --oneline

# Annotated tag — the message is what `git describe` will surface.
git tag -a v2.2.0-rc1 -m "Orion-X Phoenix Edition v2.2.0-rc1"

# Push the tag — this fires release.yml.
git push origin v2.2.0-rc1
```

Tag push triggers `.github/workflows/release.yml`. The workflow auto-flags
`prerelease: true` when the tag contains `-rc`, `-beta` or `-alpha`, and
drafts the split-part release (§3). If you publish from the build host
instead (§10), delete the CI draft first (`gh release delete <tag>`,
non-destructive while unpublished, see §6.1).

---

## 3. What CI does (release.yml)

The workflow runs on `ubuntu-latest` with a 60-minute job timeout (the same
budget as `qemu-test.yml`). Source of truth: `.github/workflows/release.yml`.
Releases come only from `v*` tag pushes; `workflow_dispatch` is a build check
(§7).

1. **Checkout** with `fetch-depth: 0`, so `CHANGELOG.md` and git history are
   available on tag events.
2. **Resolve build version.** Tag push: `ORIONX_VERSION=<tag>`. Dispatch:
   `dev-dispatch-<run id>`, which is never release-looking.
3. **Build ISO inside `debian:trixie-slim`**, privileged, the same pattern as
   `qemu-test.yml` (live-build must see a Debian host). The step runs under
   `set -o pipefail`, so a failed build cannot hide behind `tee`.
   `build-iso.sh` refuses a release-looking version with no CHANGELOG
   section, applies its live-build patches (DEC-PHASE12-112), and fails on a
   stale-stage reuse (DEC-PHASE12-113). Log: `tmp/release-build-iso.log`.
   Workspace ownership is then `chown`ed back to the runner.
4. **Verify ISO artifact.** The exact file
   `output/orionx-phoenix-edition-<version>.iso` and its `.sha256` must exist
   and match. Any other ISO in `output/` is ignored.
5. **Import the GPG key** (`crazy-max/ghaction-import-gpg@v6`). Hard-fail
   with no `continue-on-error` (DEC-PHASE12-026): no key, no release.
6. **Stage signed split release assets:**
   `stage-split-release.sh output/<iso> <tag> --out output/release`. It
   splits into 190 MiB parts, writes `SHA256SUMS` and `SHA512SUMS` (the
   whole ISO under its published name, then every part), signs both
   (`SHA256SUMS.asc`, `SHA512SUMS.asc`), renders `REASSEMBLE.txt` and
   `RELEASE-NOTES.md` (the CHANGELOG section plus download and verify
   instructions), and then proves its own output: the concatenated parts hash
   to the ISO line, every part line verifies, both signatures verify, and no
   file is 2 GiB or larger.
7. **Assert every asset is under 2 GiB** (a second, independent check).
8. **Create DRAFT GitHub Release** via `softprops/action-gh-release@v2`:
   `draft: true` always; `prerelease` from the tag shape; `body_path:
   output/release/RELEASE-NOTES.md`; `files:` the parts, both sums, both
   signatures and `REASSEMBLE.txt`, with `fail_on_unmatched_files: true`.
9. **Upload to Actions** (always): the ISO and sidecar, the sums,
   `REASSEMBLE.txt`, `RELEASE-NOTES.md` and the build log, as
   `release-artifacts-<run_id>`; then a summary step lists `output/`.

Expected wall-clock: the ISO build alone exceeds the 10–15 min it took
before the model import/consolidation step (0510); the rc9 build took 35 min
on the macOS host. Read the Actions timing of the last green run for a
current number.

---

## 4. Publishing the release (W8-7 operator approve gate)

Once the workflow completes successfully, the DRAFT exists but is **not
visible to the public**. The operator owns the publish flip. (For > 2 GB
images the same checks apply to the staged files in §10 before upload.)

### 4.1. Locate the draft

- GitHub UI: **Repository → Releases** → the draft appears at the top, tagged
  with the version and a `Draft` badge.
- CLI: `gh release view v2.2.0-rc1 --json isDraft,assets`

### 4.2. Verify the artifacts

Download the draft assets (`gh release download v2.2.0-rc1 -D tmp/release-v2.2.0-rc1`
or via the UI — never into `/tmp/`) and run, from the download directory:

```bash
# Reassemble exactly as a downloader will (REASSEMBLE.txt has the same recipe).
cat orionx-phoenix-edition-<tag>.iso.part-* > orionx-phoenix-edition-<tag>.iso

# Checksum verification: every line (the ISO and each part) must report OK.
sha256sum -c SHA256SUMS
sha512sum -c SHA512SUMS

# Signature verification.
gpg --verify SHA256SUMS.asc SHA256SUMS
gpg --verify SHA512SUMS.asc SHA512SUMS
```

`gpg --verify` exits 0 and prints `Good signature from "..."` on success.
Any other outcome is a stop-the-line event. The checksum manifests cover the
whole ISO and every part, so signing them signs the release; there is no
separate signature over the multi-GB ISO.

A draft without `.asc` files cannot exist: the import and staging steps are
hard-fail. If they failed, provision `secrets.GPG_PRIVATE_KEY` and
`secrets.GPG_PASSPHRASE` and re-run the tag build; do not sign by hand into
a CI draft.

### 4.3. Assert the image's identity matches the tag

The hash proves the file is intact; it does not prove the image *knows* which
release it is. Extract the version manifest from the squashfs and check it
(the beta shipped `ISO_VERSION=v2.2.0-trixie-dev9`):

```bash
ISO=orionx-phoenix-edition-<tag>.iso; TAG=<tag>
7z e -o"tmp/iso-check" "$ISO" live/filesystem.squashfs
unsquashfs -d tmp/iso-check/fs tmp/iso-check/filesystem.squashfs etc/orionx-version usr/share/doc/orionx/README.md
grep -x "ISO_VERSION=$TAG" tmp/iso-check/fs/etc/orionx-version || { echo "BAKED VERSION != TAG"; exit 1; }
diff -q README.md tmp/iso-check/fs/usr/share/doc/orionx/README.md || { echo "BAKED README IS STALE"; exit 1; }
rm -rf tmp/iso-check
```

Both must pass. A mismatch means rebuilding from the tagged commit (or with
`ORIONX_VERSION=$TAG` exported) — not editing the release notes around it.

### 4.4. Final preflight before publish

- Release notes (the rendered Markdown body) match the `CHANGELOG.md`
  section, including its *Known issues* list.
- Asset list contains exactly: every `.iso.part-*` named in `SHA256SUMS`,
  `SHA256SUMS`, `SHA256SUMS.asc`, `SHA512SUMS`, `SHA512SUMS.asc`,
  `REASSEMBLE.txt`. Byte sizes match (`gh release view <tag> --json assets`).
- The guided-demo assets referenced from the release notes
  (`docs/media/orionx-guided-demo-<tag>.{mp4,vtt,-poster.png,-transcript.md}`)
  are either attached to the release or linked to their `docs/media/` paths
  at the tag.

### 4.5. Flip DRAFT → Published

UI: open the draft, click **Publish release**.

CLI: `gh release edit v2.2.0-rc1 --draft=false`

This is the W8-7 `approve` gate. Once flipped, the release is public.

---

## 5. Promotion: `v2.2.0-beta` → `v2.2.0` final

When the beta has soaked and its *Known issues* are closed:

1. **Update CHANGELOG.md** — add a `## [v2.2.0] — <release date>` section
   above the beta section (keep the beta section as history; its *Known
   issues* list documents what changed). The new section is what
   `extract-release-notes.sh` returns for the `v2.2.0` tag.
2. **Bump version literals** — the touchpoints listed in §1; confirm with
   `git grep -n 'v2.2.0-beta'` that only historical references remain
   (CHANGELOG, release-process lessons, the beta's own demo video).
3. **Land on `release/2.2.0`**, then merge to `develop` after the tag. Do
   not hand-edit the bump on the integration branch.
4. **Tag from the updated head:**
   ```bash
   git fetch origin
   git checkout release/2.2.0
   git pull --ff-only origin release/2.2.0
   git tag -a v2.2.0 -m "Orion-X Phoenix Edition v2.2.0"
   git push origin v2.2.0
   ```
5. **Build and publish.** `release.yml` fires and produces a split-part DRAFT
   with `prerelease: false` (the tag has no `-rc`/`-beta`/`-alpha`); repeat
   §4. To publish from the build host instead, build with
   `ORIONX_VERSION=<tag>` exported, run §4.3 against the output, and stage
   and upload per §10; delete the CI draft first.

---

## 6. Rollback

The rollback path depends on whether the release has been **published**.

### 6.1. Pre-publish (DRAFT still unflipped)

The draft is operator-private; rolling it back is non-destructive:

```bash
gh release delete <tag>                 # deletes the draft + uploaded assets
# Note: the underlying git tag is NOT deleted by `release delete`.
```

To also remove the tag (when the tagged commit itself was wrong):

```bash
git tag -d <tag>                        # local
git push origin :refs/tags/<tag>        # remote
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

`workflow_dispatch` runs `release.yml` as a **build check**: it builds the
ISO under the development version `dev-dispatch-<run id>`, verifies it, and
uploads it to the run's Actions artifacts. It never stages, signs or drafts
a release (those steps are `if: startsWith(github.ref, 'refs/tags/v')`).

CLI: `gh workflow run release.yml --ref <branch>`

To rehearse the release asset set without publishing, stage it locally from
any ISO with `--unsigned` (never publish such a set):

```bash
bash scripts/release/stage-split-release.sh output/<iso> <tag> --out tmp/release-<tag>-dry --unsigned
```

---

## 8. Cross-references

- **Code:**
  - `.github/workflows/release.yml` — the pipeline itself
  - `scripts/release/extract-release-notes.sh` — release-notes parser (fails on a missing section)
  - `scripts/release/stage-split-release.sh` — the release asset set (parts, sums, signatures, notes)
  - `scripts/release/ci-local.sh` — the CI gates, run locally
  - `CHANGELOG.md` — single source of truth for release notes
- **Decisions (see MASTER_PLAN.md → Decision Log):**
  - `DEC-PHASE8-002` — release artifact pipeline rationale (Docker-in-CI for
    live-build, DRAFT-mode mandatory)
  - `DEC-PHASE12-026` — GPG signing is hard-fail (the earlier
    `continue-on-error` is gone)
  - `DEC-PHASE12-114` / `-115` — release identity gate; split-part asset set
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

## 10. Manual publish from the macOS build host

Used for `v2.1.0-bullseye-rain` (6.62 GB, 4 parts) and `v2.2.0-beta`
(3.09 GB, 7 parts). Use it when the ISO that passed the gates was built on the
build host, or when CI cannot build or upload. It publishes the same asset
set as CI (§0), staged by the same script; only the upload is manual.

```bash
# 0. Build with the tag's identity, then run §4.3 on output/<iso>.
ORIONX_VERSION=<tag> bash scripts/build-iso.sh

# 1. Stage, split (190 MiB parts, see §10.1), checksum, sign with the release
#    key from your local keyring, render REASSEMBLE.txt + RELEASE-NOTES.md,
#    and self-verify. Refuses a tag with no CHANGELOG section, an ISO that
#    fails its .sha256, or a signing failure.
bash scripts/release/stage-split-release.sh output/orionx-phoenix-edition-<tag>.iso <tag> \
    --out tmp/release-<tag>
R=tmp/release-<tag>

# 2. Tag the commit the ISO was built from, push branch + tag.
git tag -a <tag> -m "Orion-X Phoenix Edition <tag>" <commit>
git push origin <branch> <tag>

# 3. Create the release as a DRAFT (pre-release for beta/rc), then upload
#    serially, in the foreground, one file per command.
gh release create <tag> --draft --prerelease --title "<title>" --notes-file "$R/RELEASE-NOTES.md" \
    "$R/SHA256SUMS" "$R/SHA256SUMS.asc" "$R/SHA512SUMS" "$R/SHA512SUMS.asc" "$R/REASSEMBLE.txt"
for p in "$R"/orionx-phoenix-edition-<tag>.iso.part-*; do
    caffeinate -i gh release upload <tag> --clobber "$p"
done

# 4. Verify: every asset is state "uploaded" with the local byte size, then
#    run §4.2 on a fresh download before flipping the draft (§4.5).
gh release view <tag> --json assets --jq '.assets[]|[.name,.size]|@tsv'
ls -l "$R"
```

Never publish a bare `.part-*` set without `SHA256SUMS`, its `.asc` and
`REASSEMBLE.txt`.

### 10.1 Lessons from v2.2.0-beta (2026-09-16 → 09-19)

- **Long uploads get reset.** From the macOS build host every upload stream
  longer than roughly five minutes to `uploads.github.com` was reset mid-body
  (`gh` and `curl` alike, HTTP 400/500 or `connection reset`), while probes to
  other hosts showed a healthy 1.5–3 MB/s. Pieces of ~190 MiB (≈70 s) went
  through on the first or second try. Split finer than the 2 GB cap requires
  when uploads keep dying; `cat part-*` reassembly is unchanged.
- **Failed uploads leave a hidden `starter` asset** that blocks every retry of
  the same file name with `400 Bad Request` / `500 Error saving asset`. It is
  NOT shown by `gh release view`; list and delete it with the REST API:
  ```bash
  gh api repos/jarocki/orion/releases/<release-id>/assets --jq '.[]|[.id,.name,.state]|@tsv'
  gh api -X DELETE repos/jarocki/orion/releases/assets/<id>
  ```
- **Keep the host awake** (`caffeinate -i <uploader>`) — a sleeping laptop
  looks exactly like a stalled network.
- **Confirm completion through the API** (`state == "uploaded"` and `size`
  equal to the local file), never by reading a response file that may be
  stale from the previous part.
- Outside the repo directory, `gh release download` needs `-R jarocki/orion`.
