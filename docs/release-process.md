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

## 0. Which path is the authority

Two things decide how a tag becomes a release:

| Image size | Authority for the published assets | What `release.yml` contributes |
|---|---|---|
| ≤ 2 GB | CI draft (§3) → operator verifies and publishes (§4) | Builds, checksums, signs, drafts |
| > 2 GB (every Trixie-line image so far: v2.2.0-beta is 3.09 GB) | **Manual split-part publish from the build host (§10)** | Build check only — GitHub rejects release assets over 2 GB, so its draft cannot carry the ISO |

In both cases CI produces a **DRAFT only**; a human publishes. The `DRAFT`
boundary is non-negotiable.

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
  test; W7-4-B/W7-5/W7-6 are `continue-on-error` and informative. If the
  runner budget prevents a full run, say so in the release notes rather than
  skipping silently.
- **All documentation fixes have landed** — the ISO bakes `README.md` and
  `docs/` into `/usr/share/doc/orionx/`; the beta carried a pre-beta README.
- **Version literals bumped.** `scripts/build-iso.sh` has no version literal
  (it uses `ORIONX_VERSION` or `git describe`, DEC-PHASE7-002) and
  `iso/auto/config` only a fallback default. The real touchpoints are:
  `README.md`, `docs/User_Guide.md` (line 3 and the *About the beta* list),
  `CHANGELOG.md`, `tools/guided-demo/scenes.yaml` (`version:` — the demo
  video is re-cut per release), `docs/orionx-diag.md`, and the release notes.
  Confirm with `git grep -n 'v2.2.0-beta'`.
- **GPG signing key** is provisioned as repository secrets:
  - `secrets.GPG_PRIVATE_KEY` — ASCII-armored private key
  - `secrets.GPG_PASSPHRASE` — passphrase for the key

  Until these are provisioned, the GPG step runs with `continue-on-error: true`
  and the DRAFT release is produced **without** `.asc` signature files. The
  pipeline does not fail; the operator must either provision the key and
  re-run, or attach signatures manually before publishing. Manual publishes
  (§10) are unsigned today; `SHA256SUMS` on the release page is the integrity
  authority.
- **`CHANGELOG.md` is updated** with a section for the version you are about
  to tag. The section heading must match one of:
  - `## [2.2.0] — <date or status>`
  - `## [v2.2.0] — <date or status>`

  `extract-release-notes.sh` matches both forms (anything after the closing
  `]` is free text). If no section is found, the release body falls back to
  `"See CHANGELOG.md for full release history."`

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
`prerelease: true` when the tag contains `-rc`, `-beta` or `-alpha`. For a
> 2 GB image, treat the CI run as a build check and publish per §10; delete
the CI draft (`gh release delete <tag>` — non-destructive while unpublished,
see §6.1) before creating the manual release for the same tag.

---

## 3. What CI does (release.yml, 8 steps)

The workflow runs on `ubuntu-latest` with a 60-minute job timeout (the same
budget as `qemu-test.yml`). Source of truth: `.github/workflows/release.yml`.

1. **Checkout repository** — `actions/checkout@v4` with `fetch-depth: 0` so
   `CHANGELOG.md` and git history are always available, even on shallow tag
   triggers.
2. **Build ISO inside `debian:trixie-slim`** — same Docker pattern as
   `qemu-test.yml` (W7-1, issue #25). live-build detects the host distro, so
   we run privileged inside Debian trixie (matching `iso/auto/config`'s
   `DISTRIBUTION="trixie"`) to ensure it bootstraps from
   `deb.debian.org/trixie` rather than the Ubuntu runner's apt sources.
   `ORIONX_VERSION` is set from the tag name for tag pushes, so the baked
   `/etc/orionx-version` equals the tag; for `workflow_dispatch` it is left
   empty and `build-iso.sh` falls back to `git describe`. Output goes to
   `output/*.iso`; build log is captured to `tmp/release-build-iso.log`.
   Workspace ownership is `chown`ed back to the runner UID afterward.
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
   - `prerelease: true` — auto-flagged when the tag contains `-rc`, `-beta`
     or `-alpha`.
   - `body_path: tmp/release-notes.md`
   - `files:` glob uploads `output/*.iso`, both `SHA*SUMS`, and any `*.asc`
     that exist. `fail_on_unmatched_files: false` so a skipped GPG step does
     not break the release. **An ISO over 2 GB is rejected by GitHub at this
     step** — the draft then holds only the checksum files, which is why the
     split-part path (§10) is the authority for such images.
8. **Upload artifacts to Actions + emit summary** — `actions/upload-artifact@v4`
   always runs (`if: always()`), bundling the ISO, checksums, signatures, the
   build log, and the release notes under
   `release-artifacts-<run_id>`. A final shell step prints a Release Pipeline
   Summary with the tag, GPG signing state, and `output/` listing.

Expected wall-clock: the ISO build alone now exceeds the 10–15 min it took
before the model import/consolidation step (0510) — budget the full 60-minute
job and read the Actions timing of the last green run for a current number.

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
# Checksum verification — both must report "OK" for every artifact line.
sha256sum -c SHA256SUMS
sha512sum -c SHA512SUMS

# GPG signature verification (only if .asc files are present)
gpg --verify SHA256SUMS.asc SHA256SUMS
gpg --verify SHA512SUMS.asc SHA512SUMS
# And for each ISO:
gpg --verify orionx-phoenix-edition-<version>.iso.asc orionx-phoenix-edition-<version>.iso
```

`gpg --verify` exits 0 and prints `Good signature from "..."` on success.
Any other outcome is a stop-the-line event.

If `.asc` files are missing because the GPG key was not provisioned at CI
time, either:
- provision `secrets.GPG_PRIVATE_KEY` / `secrets.GPG_PASSPHRASE` and re-run
  the workflow via `workflow_dispatch`, then upload the new `.asc` files to
  the draft; or
- sign the artifacts locally and attach the resulting `.asc` files via
  `gh release upload v2.2.0-rc1 <files>`.

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
- Asset list contains, at minimum: ISO (or `.iso.part-*` + `REASSEMBLE.txt`),
  `SHA256SUMS`, `SHA512SUMS` where CI produced it. If GPG signing was
  expected, `.asc` siblings for each.
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
5. **Build and publish.** `release.yml` fires and produces a DRAFT with
   `prerelease: false` (the tag has no `-rc`/`-beta`/`-alpha`). If the image
   is under 2 GB, repeat §4. If it is over 2 GB — expected for v2.2.0, since
   the model is still inside the ISO — build on the build host with
   `ORIONX_VERSION=v2.2.0` exported, run §4.3 against the output, and publish
   per §10; delete the CI draft first.

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

## 10. Manual publish from the macOS build host (>2 GB ISOs)

Used for `v2.1.0-bullseye-rain` (6.62 GB, 4 parts) and `v2.2.0-beta`
(3.09 GB, 3 parts). This is the path that actually shipped both releases;
`release.yml` (§3) still builds inside `debian:bullseye-slim` and has not been
updated for the Trixie line, so it is **not** the authority for these tags.
Cancel its run if it fires on the tag push (it cannot be allowed to attach a
CI-built ISO whose hash differs from `SHA256SUMS`).

GitHub rejects release assets larger than 2 GB, so the ISO is split.

```bash
# 1. Stage from the verified build (SHA already checked against the .sha256)
R=tmp/release-<tag>; mkdir -p "$R"
cp output/orionx-phoenix-edition-<build>.iso "$R/orionx-phoenix-edition-<tag>.iso"
cd "$R"

# 2. Split into <2 GB parts. 1000 MiB keeps each upload under ~6 minutes on a
#    ~3 MB/s uplink; the host's memory-pressure reaper kills long background
#    uploads, so parts are uploaded one at a time in the foreground.
split -b 1000m orionx-phoenix-edition-<tag>.iso orionx-phoenix-edition-<tag>.iso.part-
shasum -a 256 orionx-phoenix-edition-<tag>.iso orionx-phoenix-edition-<tag>.iso.part-* > SHA256SUMS
cat orionx-phoenix-edition-<tag>.iso.part-* | shasum -a 256   # must equal the ISO line

# 3. Write REASSEMBLE.txt (cat / copy /b instructions + the ISO SHA) and the
#    release notes (from the CHANGELOG section for the tag).

# 4. Tag the commit the ISO was built from, push branch + tag.
git tag -a <tag> -m "Orion-X Phoenix Edition <tag>" <commit>
git push origin <branch> <tag>

# 5. Create the release (pre-release for beta/rc), then upload serially.
gh release create <tag> --prerelease --title "<title>" --notes-file release-notes.md \
    SHA256SUMS REASSEMBLE.txt
for p in orionx-phoenix-edition-<tag>.iso.part-*; do
    gh release upload <tag> --clobber "$p"
done

# 6. Verify: asset names + byte sizes match `ls -l`; download one part and
#    compare against SHA256SUMS.
gh release view <tag> --json assets --jq '.assets[]|[.name,.size]|@tsv'
```

Never publish a bare `.part-*` set without `SHA256SUMS` and `REASSEMBLE.txt`.

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
