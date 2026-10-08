# The Resilient Mindset — Orion-X engineering doctrine

**@decision DEC-PHASE12-037**
**@title Plan → Do → Check → Repair → Loop, as a design requirement**
**@status accepted**

Operator directive, 2026-10-01:

> Make this system RESILIENT by planning, doing, checking, repairing, and so on
> ad infinitum. Review all the things… make them verifiable and resilient.
> Don't "trust." Just verify.

This document is not aspirational. Every rule below was written after a defect
that shipped, and names it.

---

## Why this matters more here than elsewhere

Orion-X boots as root on networks someone already believes are compromised. An
operator plans around what the deck says it can do. So:

**A capability that is advertised and absent is worse than one never claimed.**

A deck with no IDS is a deck you compensate for. A deck that *says* it has an
IDS, and does not, is one you rely on and lose with. Silent degradation is the
core failure mode of this product. Loud degradation is the product.

---

## The loop

Every subsystem owes all five, not the first two:

| Stage | Obligation |
|---|---|
| **Plan** | State the desired system state as data, separately from the code that applies it. A pure function from "tier" to "what should be true" is testable; a pile of `if` statements is not. |
| **Do** | Apply it. |
| **Check** | Re-read reality. Did the thing actually happen? Build-time success is not runtime truth. |
| **Repair** | Bounded attempts, then escalate once and stop. |
| **Loop** | Re-ask on a cycle, because the answer changes. Installs fail, services die, disks fill, operators change the posture. |

A subsystem that stops at **Do** is a subsystem that lies.

---

## The eight rules, and the bug behind each

### 1. Assert effects, never implementations

`test_apparmor_profiles.sh` asserted *"Hook adds security=apparmor boot
parameter"* — i.e. that a hook edits `/etc/default/grub`. It passed
continuously while **zero AppArmor profiles were loaded**, because a live boot
never reads that file. The test verified a write, not a state.

Ask: *if this subsystem were completely broken at runtime, would this test
still pass?* If yes, it tests the implementation.

### 2. Verify at runtime, not build time

The Zeek install block was soft-fail. It failed. `iso/chroot.files` showed zero
`/opt/zeek`, while `0700` still symlinked `zeek` and `artifact-analyzer.py`
advertised it. The build "succeeded."

Anything fetched over a network can be absent later. Detect presence on a
cycle, not once.

### 3. Never report success you did not confirm

`toggle-theme.sh`:

```sh
xfconf-query ... || log "WARNING: xfconf-query failed"
log "XFCE wallpaper updated to $WALLPAPER"     # runs either way
```

It reported success in exactly the case where it had failed.

### 4. Bound every retry; escalate once; then stop

`orionx-postured` re-issued `systemctl start suricata` every 30s forever.
Suricata could never start. The loop flooded the event bus until the stream
contained nothing else.

Three attempts with backoff, then one `critical` naming the diagnosis
commands, then silence. A loop is not persistence; it is noise that hides the
thing you need to see.

### 5. Self-diagnosis is not a threat

That same loop drove **THREAT PRESSURE to "ELEVATED" on an idle machine**,
because the gauge weighted by severity and the warnings were warnings. The
deck frightened itself with its own health messages.

A gauge that rises when a service is merely unhealthy teaches the operator the
gauge means nothing. `pressure()` now excludes `health`, `posture`, `service`
and `tooling`. Health events still appear and still sound the cue — they just
are not threat, because they are not threat.

### 6. Handle the failure mode that actually occurs

`nebula-mcp` wrapped a `chown` in `try/except OSError`. Under
`SystemCallFilter=~@privileged`, seccomp does not raise — it sends **SIGSYS**
and kills the process. The handler could never run, and the code read as
careful.

Worse, the operation could not have succeeded anyway: the service runs with
`SupplementaryGroups=` empty, so `chgrp sudo` is `EPERM`. Defensive code around
an impossible operation is decoration.

### 7. One authority per fact

`toggle-theme.sh` wrote the XFCE backdrop with a hardcoded `monitor0`, which is
the exact bug `set-wallpaper.sh` was written to fix (XFCE 4.20 names backdrops
by connector). Two scripts owned the wallpaper; one was permanently broken.

The AppArmor cmdline had the same shape: `iso/auto/config` is the single
authority per DEC-PHASE11-012, and a second, dead authority in
`/etc/default/grub` quietly did nothing for years.

### 8. Degrade loudly, and name the remedy

Suricata running with no rules is indistinguishable, from the operator's seat,
from Suricata seeing nothing. That is why a live `nmap` sweep went unreported.

Every degraded state must say: what is not working, what the consequence is,
what still works, and the exact command that fixes it.

---

## What a compliant subsystem looks like

`orionx-postured` after DEC-PHASE12-034 is the reference:

- `tier_plan()` is pure — desired state as data, fully testable (**Plan**)
- `plan_actions()` diffs current against desired; `execute()` applies (**Do**)
- a 30s reassert re-reads reality rather than trusting the last apply (**Check**)
- `_suricata_recover()` makes three bounded attempts, then escalates once and
  stops (**Repair**)
- the cycle never ends, and a posture change resets the attempt budget (**Loop**)
- it announces an IDS coverage gap rather than watching nothing in silence
  (**rule 8**)

---

## Reviewing your own work

Before calling anything done:

1. If this were broken at runtime, would any test fail? Name the test.
2. What does it claim, and what does it verify? List the gap.
3. What happens on the third consecutive failure? On the hundredth?
4. Does any status it emits reach a gauge or counter that means something else?
5. Is there a second place this same fact is decided?
6. When it degrades, does the operator learn what to do?

Mutation-test the answer to (1): break the behaviour deliberately and confirm
the suite goes red. A test that passes on broken code is worse than no test —
it is a false assurance, and this project has shipped several.
