# Security Review: orion

## Scope

Standard whole-repository security scan of Orion-X at revision 38aa6ef901a02250bff5a95322e237ea9fde2748.

- Scan mode: repository
- Target kind: git_revision
- Target ID: target_sha256_4c121927adcb1a8b9397f2fe033a93ec89c17ea137e5d5cec6c32bb472266930
- Revision: 38aa6ef901a02250bff5a95322e237ea9fde2748
- Inventory strategy: repository
- Included paths: .
- Excluded paths: none
- Artifacts reviewed: README.md, docs/, iso/, scripts/, tests/, Dockerfile, docker-compose.yml
- Scan context: Threat model reconciled with the current user-supplied PHILOSOPHY.md; findings independently validated.

Limitations and exclusions:
- Three usable worker slots rather than six recommended.
- Hardware-specific systemd, nftables, WireGuard, AppArmor, cgroup, and raw-device behavior remains untested.

### Scan Summary

| Field | Value |
| --- | --- |
| Scan outcome | completed |
| Reportable findings | 9 |
| Severity mix | high: 1, medium: 7, low: 1 |
| Confidence mix | high: 8, medium: 1 |
| Coverage | complete |
| Validation mode | Independent source validation plus harmless offline triggers where feasible. |

Canonical artifacts: `scan-manifest.json`, `findings.json`, and `coverage.json`. This report is a deterministic projection of those files.

## Threat Model

Orion-X at revision 38aa6ef901a02250bff5a95322e237ea9fde2748 is primarily a Debian trixie amd64 live-USB incident-response environment, with separate host-side build/release and imaging workflows and a materially different Docker toolkit deployment. The live image combines default-deny inbound filtering, WireGuard mesh, a world-writable awareness bus with separately attested root healing, posture enforcement, bounded capture, local Ollama/MCP services, optional Matrix, Cockpit, and Pivotglass. The review treats source-derived evidence as authority, keeps automated findings advisory, and preserves explicit operator control in line with the current PHILOSOPHY.md.

### Assets

- Incident evidence and analyst state: packet captures, Analysis files, Pivotglass workspaces/raw documents, Matrix state, logs, and exports (scripts/awareness/orionx-capture:75-77; scripts/pivotglass/pivotglass/core/workspace.py:183,232-303,1583-1600).
- Identity and authority: the autologin live operator, passwordless sudo/polkit, root daemons, Linux capabilities, and host-administrator authority used by the imager (scripts/security/first-boot-wizard.sh:275-360; scripts/orionx-imager/lib/writer.py:1-19).
- Secrets and cryptographic state: WireGuard private key and optional team PSK, Matrix secrets, Wi-Fi keyfile, provider credentials, and the R.A.I.N. attestation key (scripts/mesh/mesh-lib.sh:33-56,435-488; scripts/rain/rain_lib.py:265-346).
- Integrity and truthful-state controls: model manifests, ISO/release checksums, event records, MCP audit records, healing ledger, firewall/mesh/posture status, and capture bounds.

### Trust Boundaries

- Physical operator to live desktop/root: autologin and passwordless root are intentional single-user appliance behavior, not a privilege boundary (README.md:385-386; scripts/security/first-boot-wizard.sh:275-360).
- Hostile LAN to network stack and mesh discovery: nftables limits ordinary inbound traffic, but UDP discovery can propose a new WireGuard peer and optional PSK material changes the authorization boundary (iso/config/includes.chroot/etc/nftables.conf:33-77; scripts/mesh/mesh-discover.sh:174-273).
- Local event producers to root healing: any local process can publish awareness records, while root effects require HMAC, freshness/replay checks, live consent, guards, and rate limits (scripts/rain/rain_lib.py:52-57,265-372; scripts/healing/engine.py:169-359).
- Operator configuration to privileged daemons: posture, tuning, and healing consent are user-owned inputs consumed by root through trusted-read and fail-closed parsing controls.
- Model/client to local MCP tools: normal service use is AF_UNIX-only under a dedicated uid with no IP network and read-only evidence roots; direct stdio use inherits the caller's authority (scripts/nebula/mcp_server.py:135-220,603-612).
- Local browser to Pivotglass and optional providers: normal web launch is loopback-only with Host and same-origin controls; selected provider operations may transmit queries and credentials externally.
- Build/release inputs to model, ISO, cache, and raw-device writer: pinned hashes and release manifests are expected to bind downloaded bytes before boot or device writes (scripts/build-iso.sh:638-778; scripts/orionx-imager/lib/downloader.py:265-310).
- Docker deployment is not security-equivalent to the live ISO; its NET_ADMIN/SYS_PTRACE capabilities, bind mount, and published port form a separate boundary (docker-compose.yml:3-18).

### Attacker Capabilities

- A same-LAN unauthenticated host can send discovery datagrams and claim a new key and unused mesh address; further impact depends on peer authorization controls and services admitted on wg0.
- A local unprivileged process can append unsigned awareness events but cannot create a verified healing trigger without the root-only HMAC key.
- Malicious evidence, packets, JSON/web requests, model-generated MCP requests, and provider responses may influence parsers and downstream analysis; release or root credentials are not assumed compromised.
- A physical console user and the normal live operator can become root by design, so same-operator findings require a distinct security impact beyond privilege elevation.

### Security Objectives

- Keep local AI and MCP execution confined to intended loopback/AF_UNIX, filesystem, tool-registry, timeout, and audit boundaries.
- Do not let the world-writable awareness channel directly become root execution authority or unbounded root-side amplification.
- Require effective operator intent or cryptographic authorization before privileged mesh membership changes.
- Keep capture, posture, firewall, Matrix, and healing actions bounded, fail-closed, and truthful about effective runtime state.
- Bind downloaded release/model bytes to required integrity metadata before boot or destructive raw-device writes unless the operator explicitly selects a documented bypass.
- Preserve evidence provenance, uncertainty, analyst accountability, and explicit user control.

### Assumptions

- Scope is the tracked repository at exact revision 38aa6ef901a02250bff5a95322e237ea9fde2748; runtime enforcement has not been exercised on a physical deck in this scan.
- The Debian live ISO is the primary deployment; Docker is a distinct compatibility/toolbox deployment.
- The default live system is ephemeral unless persistence is configured.
- No repository SECURITY.md exists. The user-required current PHILOSOPHY.md was fetched from the supplied main-branch URL and reconciled by the parent review.
- Direct/debug MCP, capture, and healing startup paths deliberately inherit more caller authority than the systemd service paths.

## Findings

| Finding | Severity | Confidence | Detailed write-up |
| --- | --- | --- | --- |
| [Opening a maliciously named capture executes shell commands](#finding-1) | high | high | inline below |
| [Downloaded ISO is accepted when the checksum manifest is missing](#finding-2) | medium | high | inline below |
| [Encrypted installation exposes and then destroys its only LUKS key](#finding-3) | medium | high | inline below |
| [Workspace CSV exports preserve attacker-controlled spreadsheet formulas](#finding-4) | medium | high | inline below |
| [Programmatic LAN binding exposes the Pivotglass cockpit without authentication](#finding-5) | medium | high | inline below |
| [Tier-2 decoys publish a root event before connection admission](#finding-6) | medium | high | inline below |
| [Unauthenticated LAN beacons enroll peers into the privileged mesh](#finding-7) | medium | high | inline below |
| [Unsigned events suppress the shared bus and amplify root-side work](#finding-8) | medium | high | inline below |
| [Discovery forks before validating or throttling each datagram](#finding-9) | low | medium | inline below |

### Confidence Scale

| Label | Meaning |
| --- | --- |
| high | Direct evidence supports the finding with no material unresolved blocker. |
| medium | Evidence supports a plausible issue, but material runtime or reachability proof remains. |
| low | Evidence is incomplete and the item is retained only for explicit follow-up. |

<a id="finding-1"></a>

### [1] Opening a maliciously named capture executes shell commands

| Field | Value |
| --- | --- |
| Severity | high |
| Confidence | high |
| Confidence rationale | An existing filename containing shell separators caused a marker command to run. The Control Center passes the selected path directly, and the analyzer uses `shell=True`. |
| Category | OS command injection |
| CWE | CWE-78 |
| Affected lines | scripts/artifact-analyzer.py:250-256, scripts/artifact-analyzer.py:475-501, scripts/control_center/sections/ir.py:89-95 |

#### Summary

`artifact-analyzer.py` interpolates an existing capture filename and output path into a command passed to `subprocess.run(..., shell=True)`, so shell metacharacters in attacker-supplied evidence names execute as the analyst.

#### Root Cause

Evidence paths should remain inert data, but the analyzer constructs one shell command string from the caller-controlled filename instead of using fixed argv and a Python-owned output stream.

#### Validation

An existing filename containing shell separators caused a marker command to run. The Control Center passes the selected path directly, and the analyzer uses `shell=True`.

Validation method: Static source trace plus harmless offline trigger with fake forensic tools

Assertions:
- An existing filename containing shell separators caused a marker command to run. The Control Center passes the selected path directly, and the analyzer uses `shell=True`.

Limitations:
- Real `tshark` and `zeek` were replaced with local fakes; shell parsing is independent of their implementation.

#### Dataflow

artifact path -\> CLI or Control Center -\> formatted command string -\> shell -\> attacker-selected command

- **Source:** attacker-controlled existing capture filename

- **Sink:** `subprocess.run` with `shell=True`

- **Outcome:** arbitrary command execution as the analyst

#### Reachability

The artifact must exist and both forensic tools must be available; the ISO contract includes those tools.

- **Attacker:** party able to supply or name a capture artifact

- **Entry point:** artifact analyzer CLI or Control Center file picker

- **Outcome:** arbitrary command execution as the analyst

Limitations:
- Real `tshark` and `zeek` were replaced with local fakes; shell parsing is independent of their implementation.

#### Severity

**High** — A normal evidence-analysis action can execute arbitrary commands under the highly trusted analyst account, which has passwordless administrative authority in the live appliance.

Lower if artifact names are guaranteed to originate only from a trusted capture subsystem and cannot be renamed or supplied externally.

#### Remediation

Replace the shell command with a fixed `tshark` argv, structured `(name, expression)` filters, and Python-opened output files passed as `stdout`.

Tests:
- Use filenames/output directories containing spaces, quotes, semicolons, and command-substitution syntax and assert no marker runs.
- Assert `tshark` receives list argv and no `shell=True`.

Preventive controls:
- Ban `shell=True` in forensic artifact handlers.
- Keep attacker-controlled paths out of shell strings.

<a id="finding-2"></a>

### [2] Downloaded ISO is accepted when the checksum manifest is missing

| Field | Value |
| --- | --- |
| Severity | medium |
| Confidence | high |
| Confidence rationale | A fake release with an ISO and no manifest returned attacker-selected bytes while `skip_verify=False`; the explicit skip path was unused. |
| Category | Missing integrity verification |
| CWE | CWE-353 |
| Affected lines | scripts/orionx-imager/lib/downloader.py:159-172, scripts/orionx-imager/lib/downloader.py:265-310, scripts/orionx-imager/orionx-imager:317-323 |

#### Summary

`download_and_verify()` turns a missing `SHA256SUMS` asset into a warning and returns the downloaded ISO with verification enabled, bypassing the promised mandatory default gate without the explicit two-flag opt-out.

#### Root Cause

The shared default downloader violates the invariant that no downloaded ISO returns unless its digest is present and matches.

#### Validation

A fake release with an ISO and no manifest returned attacker-selected bytes while `skip_verify=False`; the explicit skip path was unused.

Validation method: Static call trace plus fake-release offline trigger

Assertions:
- A fake release with an ISO and no manifest returned attacker-selected bytes while `skip_verify=False`; the explicit skip path was unused.

Limitations:
- This check does not protect against compromise of both release bytes and manifest under the same authority.

#### Dataflow

release metadata -\> missing-manifest branch -\> ISO download -\> success -\> writer

- **Source:** release asset list and downloaded ISO

- **Sink:** raw-device imaging workflow

- **Outcome:** unverified boot media accepted as verified

#### Reachability

The operator chooses a downloaded release and does not explicitly bypass verification.

- **Attacker:** party able to alter release metadata or asset delivery

- **Entry point:** downloaded-release imager mode

- **Outcome:** unverified boot media accepted as verified

Limitations:
- This check does not protect against compromise of both release bytes and manifest under the same authority.

#### Severity

**Medium** — Malformed or substituted release metadata can supply bytes for destructive imaging without the product's required integrity check. HTTPS and same-release authority limit but do not replace that control.

Higher if the manifest is independently signed; lower if the release API makes a missing manifest cryptographically impossible.

#### Remediation

Raise before any ISO/part download when verification is enabled and no checksum manifest exists; preserve only the explicit two-flag bypass.

Tests:
- Missing manifest raises before ISO download by default.
- Explicit `skip_verify=True` remains supported.
- Valid whole, split, mismatch, and cache cases remain green.

Preventive controls:
- Enforce verification in the shared GUI/CLI downloader.
- Make UI messages reflect actual verification state.

<a id="finding-3"></a>

### [3] Encrypted installation exposes and then destroys its only LUKS key

| Field | Value |
| --- | --- |
| Severity | medium |
| Confidence | high |
| Confidence rationale | Creation under umask 022 produced a readable key file, and no `luksAddKey` or first-boot enrollment path exists. |
| Category | Insecure temporary secret file |
| CWE | CWE-377, CWE-732 |
| Affected lines | scripts/install.sh:148-169, scripts/install.sh:180-200, iso/config/includes.chroot/opt/orionx/scripts/install.sh:148-169 |

#### Summary

Both encrypted-install branches write the sole LUKS key to `/tmp/tempkey` with inherited permissions, use it for `luksFormat` and `luksOpen`, then delete it without enrolling the promised first-boot passphrase.

#### Root Cause

The installer handles an encryption secret in a predictable shared path without restrictive creation or cleanup controls, and the claimed later passphrase replacement does not exist.

#### Validation

Creation under umask 022 produced a readable key file, and no `luksAddKey` or first-boot enrollment path exists.

Validation method: Static trace, offline filesystem primitive, and repository-wide key-enrollment search

Assertions:
- Creation under umask 022 produced a readable key file, and no `luksAddKey` or first-boot enrollment path exists.

Limitations:
- Debian protected-symlink settings may block some pre-plant attacks but do not prevent creation of a readable key.

#### Dataflow

root installer -\> fixed shared key path -\> `cryptsetup` sole key -\> readable interval -\> deletion without replacement

- **Source:** installer-generated random key under inherited umask

- **Sink:** shared `/tmp/tempkey` and LUKS keyslot

- **Outcome:** confidentiality loss and permanent unlock failure

#### Reachability

Root must run the legacy installer with encrypted persistence enabled; disclosure does not depend on symlink pre-plant success.

- **Attacker:** local unprivileged process present during installation

- **Entry point:** encrypted persistence option

- **Outcome:** confidentiality loss and permanent unlock failure

Limitations:
- Debian protected-symlink settings may block some pre-plant attacks but do not prevent creation of a readable key.

#### Severity

**Medium** — Under a common `022` umask, a local process can read the sole disk-encryption key during installation; deletion without replacement also leaves the volume permanently unlockable.

Lower if installation is isolated and enforces `umask 077`; higher if multi-user installation is a primary deployment.

#### Remediation

Remove the temporary key and use interactive `cryptsetup luksFormat` and `cryptsetup luksOpen` through one shared helper so the operator enrolls the durable passphrase during installation.

Tests:
- Assert neither shipped installer contains `/tmp/tempkey`.
- Stub `cryptsetup` and verify both boot modes use the shared interactive helper.
- Run `bash -n` and shellcheck.

Preventive controls:
- Use one encryption helper for both boot modes.
- Never place cryptographic key material in shared temporary namespaces.

<a id="finding-4"></a>

### [4] Workspace CSV exports preserve attacker-controlled spreadsheet formulas

| Field | Value |
| --- | --- |
| Severity | medium |
| Confidence | high |
| Confidence rationale | Both exporters emitted `=WEBSERVICE(...)`, `+1+1`, and whitespace-prefixed `@SUM(...)` unchanged; graph CSV already contains the missing control. |
| Category | CSV formula injection |
| CWE | CWE-1236 |
| Affected lines | scripts/pivotglass/pivotglass/web/server.py:1412-1425, scripts/pivotglass/pivotglass/agent/tools.py:2567-2580, scripts/pivotglass/pivotglass/core/investigation_graph_export.py:243-244 |

#### Summary

Both workspace CSV exporters pass scalar STIX/custom fields directly to `csv.DictWriter`; provider-controlled values beginning with spreadsheet formula markers remain active when an analyst opens the export.

#### Root Cause

CSV quoting does not neutralize formulas, and the workspace exporters do not reuse the graph exporter's cell-safety helper.

#### Validation

Both exporters emitted `=WEBSERVICE(...)`, `+1+1`, and whitespace-prefixed `@SUM(...)` unchanged; graph CSV already contains the missing control.

Validation method: Static provider-to-workspace trace plus exact exporter-body execution

Assertions:
- Both exporters emitted `=WEBSERVICE(...)`, `+1+1`, and whitespace-prefixed `@SUM(...)` unchanged; graph CSV already contains the missing control.

Limitations:
- Impact depends on the spreadsheet and its external-content policy.

#### Dataflow

provider response -\> workspace scalar -\> CSV exporter -\> spreadsheet parser

- **Source:** provider-controlled scalar

- **Sink:** formula-capable spreadsheet cell

- **Outcome:** formula execution in analyst context

#### Reachability

The analyst must export and open CSV in susceptible software.

- **Attacker:** external intelligence source or scanned asset

- **Entry point:** web or agent CSV export

- **Outcome:** formula execution in analyst context

Limitations:
- Impact depends on the spreadsheet and its external-content policy.

#### Severity

**Medium** — An export/open step is required, but formulas can trigger requests, data exfiltration, or local actions depending on spreadsheet policy.

Lower if CSV is guaranteed to remain inert text; higher if exports are automatically opened in a formula-capable spreadsheet.

#### Remediation

Create one shared `spreadsheet_safe_cell` helper and apply it to every scalar cell in both workspace exporters and graph CSV.

Tests:
- Cover `=`, `+`, `-`, `@`, leading whitespace, tabs, and carriage returns in both paths.
- Benign values and non-strings remain unchanged.
- JSON/STIX/GEXF remain unchanged.

Preventive controls:
- Centralize spreadsheet-cell encoding.
- Apply it at every CSV output boundary.

<a id="finding-5"></a>

### [5] Programmatic LAN binding exposes the Pivotglass cockpit without authentication

| Field | Value |
| --- | --- |
| Severity | medium |
| Confidence | high |
| Confidence rationale | `run_web` accepted `192.0.2.10`; its handler returned state for that Host and accepted a no-Origin JSON mutation without any credential. |
| Category | Missing authentication for critical function |
| CWE | CWE-306 |
| Affected lines | scripts/pivotglass/pivotglass/web/server.py:2259-2280, scripts/pivotglass/pivotglass/web/server.py:1953-1977, scripts/pivotglass/pivotglass/web/server.py:1979-2242 |

#### Summary

`run_web(host=<LAN address>)` accepts and binds a non-loopback address, adds it to the Host allowlist, and exposes state and mutation APIs without an identity check; JSON requests without `Origin` pass the mutation gate.

#### Root Cause

Host allowlisting and browser-origin checks are not authentication, yet the public launcher explicitly permits an address that makes the cockpit remotely reachable.

#### Validation

`run_web` accepted `192.0.2.10`; its handler returned state for that Host and accepted a no-Origin JSON mutation without any credential.

Validation method: Static source trace plus exact-function offline execution with stub server

Assertions:
- `run_web` accepted `192.0.2.10`; its handler returned state for that Host and accepted a no-Origin JSON mutation without any credential.

Limitations:
- The shipped launcher uses the safe loopback default and exposes no host option.

#### Dataflow

host argument -\> LAN bind/allowlist -\> unauthenticated GET or POST -\> workspace/provider action

- **Source:** remote HTTP request

- **Sink:** cockpit state and command/configuration handlers

- **Outcome:** investigation disclosure and unauthorized actions

#### Reachability

Requires a local caller to opt into the supported LAN-address mode.

- **Attacker:** reachable LAN peer

- **Entry point:** programmatic `run_web(host=...)`

- **Outcome:** investigation disclosure and unauthorized actions

Limitations:
- The shipped launcher uses the safe loopback default and exposes no host option.

#### Severity

**Medium** — The mode is nondefault and programmatic, but once enabled any reachable peer can read investigation state, mutate workspaces/configuration, and trigger configured integrations.

Higher if the shipped CLI exposes LAN binding or enables it by default; lower if the callable is private and unreachable outside tests.

#### Remediation

Reject every non-loopback host before constructing the service or server; design any future remote mode separately with authentication and TLS.

Tests:
- Reject LAN IPv4/IPv6, wildcards, and hostnames before server construction.
- Accept `localhost`, loopback IPv4, and `::1`.
- Preserve Host/origin defenses.

Preventive controls:
- Keep unauthenticated cockpit service loopback-only.
- Threat-model remote mode as a separate authenticated interface.

<a id="finding-6"></a>

### [6] Tier-2 decoys publish a root event before connection admission

| Field | Value |
| --- | --- |
| Severity | medium |
| Confidence | high |
| Confidence rationale | With the semaphore exhausted, 100 accepts still caused 100 callbacks; each callback reaches a process-spawning publisher and firewall admission has no rate expression. |
| Category | Allocation of resources without limits |
| CWE | CWE-770 |
| Affected lines | scripts/awareness/orionx-postured:1728-1750, scripts/awareness/orionx-postured:1412-1444, scripts/awareness/orionx-postured:1803-1807, scripts/awareness/orionx-postured:2801-2804 |

#### Summary

Every Tier-2 decoy accept invokes `on_hit` before the 32-connection semaphore, and each hit spawns `orionx-event`. The inserted firewall rule accepts decoy ports without a connection-rate limit.

#### Root Cause

The semaphore limits tarpit threads but not the pre-admission detection callback, event publication, or network admission rate.

#### Validation

With the semaphore exhausted, 100 accepts still caused 100 callbacks; each callback reaches a process-spawning publisher and firewall admission has no rate expression.

Validation method: Static call trace plus offline fake-socket trigger

Assertions:
- With the semaphore exhausted, 100 accepts still caused 100 callbacks; each callback reaches a process-spawning publisher and firewall admission has no rate expression.

Limitations:
- No live nftables/process-exhaustion run was performed on a deck.

#### Dataflow

TCP connect -\> firewall accept -\> socket accept -\> pre-semaphore callback -\> `Popen(orionx-event)`

- **Source:** remote decoy connection

- **Sink:** root child process, spool, and journal

- **Outcome:** resource amplification

#### Reachability

Operator must enable Tier 2; the 32-slot semaphore does not protect publication.

- **Attacker:** network peer reaching Tier-2 ports

- **Entry point:** TCP 23, 2121, 2222, or 4444

- **Outcome:** resource amplification

Limitations:
- No live nftables/process-exhaustion run was performed on a deck.

#### Severity

**Medium** — A LAN peer can turn opt-in decoys into sustained root-side process, spool, and journal amplification; the service memory cap does not bound child creation.

Higher if Tier 2 becomes default or live tests show host-wide instability; lower with firewall and in-process publication limits.

#### Remediation

Apply global/per-peer token buckets before publication, aggregate suppressed hits, add an nftables new-connection limit, and use a persistent bounded publisher.

Tests:
- 100 accepts over capacity produce only bounded publication.
- First hit alerts and rollover emits one aggregate.
- Firewall rule includes a new-connection limit.

Preventive controls:
- Avoid one subprocess per observation.
- Add service `TasksMax` and `CPUQuota`.

<a id="finding-7"></a>

### [7] Unauthenticated LAN beacons enroll peers into the privileged mesh

| Field | Value |
| --- | --- |
| Severity | medium |
| Confidence | high |
| Confidence rationale | A valid beacon reached stubbed `wg set` without a PSK; repository docs and decision notes already call for candidate-only behavior without PSK. |
| Category | Missing authentication for critical function |
| CWE | CWE-306 |
| Affected lines | scripts/mesh/mesh-discover.sh:174-209, scripts/mesh/mesh-lib.sh:351-380, iso/config/includes.chroot/etc/nftables.conf:44-63 |

#### Summary

Default discovery accepts a well-formed UDP beacon from any LAN host and invokes `wg set` with its public key, claimed free address, and sender endpoint. The optional PSK means no shared authorization is required in the normal no-PSK path.

#### Root Cause

Shape and collision validation do not prove authorization, yet discovery promotes a new candidate to the privileged peer table when no authentication material exists.

#### Validation

A valid beacon reached stubbed `wg set` without a PSK; repository docs and decision notes already call for candidate-only behavior without PSK.

Validation method: Static source trace plus existing offline discovery harness

Assertions:
- A valid beacon reached stubbed `wg set` without a PSK; repository docs and decision notes already call for candidate-only behavior without PSK.

Limitations:
- Further access depends on enabled services, which retain authentication.

#### Dataflow

UDP beacon -\> validation -\> `mesh_add_peer` -\> `wg set` -\> `wg0` trust

- **Source:** unauthenticated beacon and sender IP

- **Sink:** kernel WireGuard peer table

- **Outcome:** unauthorized mesh membership

#### Reachability

Discovery must be active; config mode is safe; a correctly shared PSK blocks handshake.

- **Attacker:** same-LAN unauthenticated host

- **Entry point:** UDP/55555 after discovery join

- **Outcome:** unauthorized mesh membership

Limitations:
- Further access depends on enabled services, which retain authentication.

#### Severity

**Medium** — A same-LAN attacker cannot steal occupied addresses or bypass SSH/Matrix credentials, but can cause automatic trusted-interface membership.

Higher if a `wg0` service lacks authentication or discovery is automatic; lower if PSK is mandatory.

#### Remediation

Without a configured PSK, save a bounded candidate and require explicit operator approval before `wg set`; retain auto-add only with PSK.

Tests:
- No-PSK beacon never calls `wg set` and creates one candidate.
- Approval adds the exact candidate.
- PSK auto-add and collision/rewrite protections remain.

Preventive controls:
- Expose discovery authorization state.
- Expire/cap candidates.

<a id="finding-8"></a>

### [8] Unsigned events suppress the shared bus and amplify root-side work

| Field | Value |
| --- | --- |
| Severity | medium |
| Confidence | high |
| Confidence rationale | Twenty forged protected-target events produced twenty root refusal records and publish requests; truncation before polling suppressed a valid event. |
| Category | Uncontrolled resource consumption and shared-channel integrity |
| CWE | CWE-400, CWE-732 |
| Affected lines | scripts/rain/rain_lib.py:52-57, scripts/rain/rain_lib.py:418-425, scripts/healing/engine.py:272-324, scripts/healing/orionx-heald:119-144 |

#### Summary

Any local process can append, truncate, or grow the mode-0666 R.A.I.N. spool. The root healer matches unsigned events and performs guard, ledger, speech, and publication side effects before rejecting their authority.

#### Root Cause

Authentication occurs after matching, and `consider()` performs guard/refusal side effects before the unverified branch; the authoritative queue is also a writable regular file.

#### Validation

Twenty forged protected-target events produced twenty root refusal records and publish requests; truncation before polling suppressed a valid event.

Validation method: Static call trace plus unsigned-event storm and truncation triggers

Assertions:
- Twenty forged protected-target events produced twenty root refusal records and publish requests; truncation before polling suppressed a valid event.

Limitations:
- The unit memory cap, ephemeral `/run`, and single-operator model reduce persistence and likelihood.

#### Dataflow

local file write -\> root tailer -\> match -\> pre-auth side effects -\> ledger/process

- **Source:** mode-0666 event spool

- **Sink:** root ledger, publisher, journal, and queue state

- **Outcome:** alert suppression and resource exhaustion

#### Reachability

No HMAC is needed for availability/integrity impact; HMAC correctly blocks playbook execution.

- **Attacker:** unprivileged local process

- **Entry point:** `/run/orionx/events.jsonl`

- **Outcome:** alert suppression and resource exhaustion

Limitations:
- The unit memory cap, ephemeral `/run`, and single-operator model reduce persistence and likelihood.

#### Severity

**Medium** — A local process cannot execute playbooks but can suppress security events and repeatedly induce root-owned writes and child processes.

Higher in multi-user deployments or on disk-backed storage; lower if untrusted local processes cannot access the spool.

#### Remediation

Reject unattested bus events before any `consider()` side effect and replace regular-file ingress with a bounded root-owned Unix socket broker enforcing size, credential, and rate limits.

Tests:
- Unsigned storm produces no ledger/speech/publish side effects.
- Signed events still follow consent and guards.
- Clients cannot truncate authoritative queue and oversize messages are dropped.

Preventive controls:
- Throttle before mapping/persistence/subprocess work.
- Bound and rotate awareness/healing records.

<a id="finding-9"></a>

### [9] Discovery forks before validating or throttling each datagram

| Field | Value |
| --- | --- |
| Severity | low |
| Confidence | medium |
| Confidence rationale | The listener contains `fork`; validation/state creation occurs only in children; no child, task, or CPU limit is configured. |
| Category | Allocation of resources without limits |
| CWE | CWE-770 |
| Affected lines | scripts/mesh/mesh-discover.sh:233-271, scripts/mesh/mesh-discover.sh:351-368, iso/config/includes.chroot/usr/share/orionx/systemd/orionx-mesh-discover.service:38-64 |

#### Summary

The UDP listener asks `socat` to fork a shell per datagram before validation and per-sender throttling. Nftables materially limits rate, but still permits bursts and sustained workers while sender stamp files remain uncapped.

#### Root Cause

The network admission point allocates a process before validating input, with no hard concurrency cap in the listener or unit.

#### Validation

The listener contains `fork`; validation/state creation occurs only in children; no child, task, or CPU limit is configured.

Validation method: Static trace, listener-argument harness, and existing mesh tests

Assertions:
- The listener contains `fork`; validation/state creation occurs only in children; no child, task, or CPU limit is configured.

Limitations:
- No live `socat` flood was run and exact child-limit syntax needs target verification.

#### Dataflow

datagram -\> nft allowance -\> `socat fork` -\> handler -\> stamp/lock

- **Source:** hostile discovery traffic

- **Sink:** process table and `/run` state

- **Outcome:** CPU/memory/process/inode pressure

#### Reachability

Requires discovery mode; nftables substantially bounds throughput.

- **Attacker:** same-LAN sender

- **Entry point:** active UDP/55555 listener

- **Outcome:** CPU/memory/process/inode pressure

Limitations:
- No live `socat` flood was run and exact child-limit syntax needs target verification.

#### Severity

**Low** — The service is opt-in, invalid handlers are short-lived, and nftables limits to 20 packets per second with burst 40, but missing child/state caps create avoidable low-memory pressure.

Higher if firewall limits are absent/bypassable or live testing shows instability.

#### Remediation

Use a bounded listener/worker design; at minimum configure a verified child limit plus systemd `TasksMax`, `MemoryMax`, and `CPUQuota`, and cap/expire sender state.

Tests:
- Effective listener/unit show verified limits.
- Representative flood keeps concurrent workers bounded.
- Legitimate multi-peer discovery succeeds.

Preventive controls:
- Validate before state allocation.
- Use fixed-cardinality expiring rate state.

## Reviewed Surfaces

| Surface | Risk Area | Outcome | Notes |
| --- | --- | --- | --- |
| Architecture and effective configuration | Trust boundaries and deployed control ownership | No issue found | Threat model completed and reconciled with current PHILOSOPHY.md. |
| Privileged healing and event bus | Local-to-root authority, resource amplification, command dispatch | Reported | Unsigned-event suppression/amplification reported; no playbook-execution bypass survived. |
| WireGuard discovery and privileged mesh mutation | Unauthenticated LAN enrollment and resource limits | Reported | No-PSK enrollment and bounded-severity worker exhaustion reported. |
| Repository-wide baseline | Cross-cutting security regressions | No issue found | Independent baseline complete; survivors are reported on specific surfaces. |
| Artifact analyzer network command execution | Untrusted filenames reaching shell execution | Reported | Offline trigger confirmed command execution. |
| Installer secret-file handling | LUKS key confidentiality and temporary-file safety | Reported | Readable sole LUKS key reported; predictable log path suppressed as defense in depth. |
| Imager release integrity | Downloaded ISO verification before destructive write | Reported | Missing manifest succeeds without explicit skip. |
| Pivotglass network exposure | Remote cockpit authentication | Reported | Programmatic LAN binding exposes APIs without authentication. |
| Pivotglass CSV export | Spreadsheet formula injection | Reported | Both workspace CSV paths preserve formulas. |
| Tier-2 deception listeners | Network-triggered event/process amplification | Reported | Publication occurs before capacity admission. |
| Nebula MCP and local AI confinement | Tool authorization, paths, network, filesystem | No issue found | No reportable service-path bypass survived; direct debug mode inherits caller authority. |
| Capture and forensic storage | Interface/path validation and bounds | No issue found | Normal capture path revalidates requests and bounds time/space. |
| Pivotglass ingestion and SQL | Traversal, parser exhaustion, injection | No issue found | Storage and query controls prevented reportable paths. |
| Credentials and embedded secrets | Hardcoded access material | No issue found | Reviewed values were placeholders, public values, canaries, or fixtures. |
