"""background — keep blocking probes off the GTK main loop (DEC-PHASE12-068).

@decision DEC-PHASE12-068
@title Probes run in worker threads, results land via GLib.idle_add, hidden tabs do not poll
@status accepted
@rationale python.md P1-5 / P2-7 / P2-8, ux.md UX-28. Every tab polled on the
  GTK thread whether visible or not: about 390 synchronous forks a minute
  (systemctl, nmcli, ip, `nebula status --json`, matrix-commander with 12 s +
  15 s timeouts), so one slow probe froze the whole Cockpit, and opening it
  with an unreachable homeserver took over 30 s. The rule now:
    - `collect` (anything that forks, reads a slow file or may time out)
      runs in a daemon thread; `apply` (anything that touches a widget) runs
      on the main loop through GLib.idle_add. Widgets are never touched from
      a thread.
    - a Poller only collects while its owner widget is mapped, i.e. its tab is
      the visible one, and collects immediately when the tab is shown. A
      poller that must keep watching while hidden (Awareness service alerts)
      says so with run_hidden=True and receives visible=False so it can do
      the minimum.
    - one collection in flight per poller; a stalled probe skips ticks
      instead of stacking threads.
  Every subprocess a collector runs still carries a timeout.
  The old rule "no threads" (DEC-PHASE12-007) is superseded for the GTK
  tabs and the LIVE probes; drawing stays on the main loop.
"""
from __future__ import annotations

import threading
from typing import Any, Callable, Optional

try:
    from gi.repository import GLib  # type: ignore[import]
except ImportError:  # pragma: no cover - test hosts without gi
    GLib = None  # type: ignore[assignment]


def run_async(work: Callable[[], Any], done: Callable[[Any, Optional[BaseException]], None]) -> threading.Thread:
    """Run `work()` in a daemon thread; call `done(result, error)` on the main loop.

    `error` is the exception `work` raised (result is then None), so the
    caller can show the actual error instead of swallowing it.
    """
    def _deliver(res: Any, err: Optional[BaseException]) -> bool:
        done(res, err)
        return False

    def _thread() -> None:
        try:
            res, err = work(), None
        except Exception as exc:  # noqa: BLE001 - delivered to the caller, not hidden
            res, err = None, exc
        GLib.idle_add(_deliver, res, err)

    t = threading.Thread(target=_thread, name="orionx-probe", daemon=True)
    t.start()
    return t


class Poller:
    """Collect in a thread every `interval_ms` while `owner` is visible; apply on the main loop."""

    instances: list = []     # introspection for tests/unit/cockpit_gtk_checks.py

    def __init__(self, owner: Any, interval_ms: int,
                 collect: Callable[[bool], Any],
                 apply: Callable[[Any, Optional[BaseException]], None],
                 run_hidden: bool = False) -> None:
        self.owner, self.collect, self.apply = owner, collect, apply
        self.run_hidden = run_hidden
        self.busy = False
        self.runs = 0
        Poller.instances.append(self)
        GLib.timeout_add(interval_ms, self._tick)
        owner.connect("map", lambda *_a: self.kick())

    def visible(self) -> bool:
        return bool(self.owner.get_mapped())

    def kick(self) -> bool:
        """Start one collection now (unless one is already running)."""
        vis = self.visible()
        if self.busy or not (vis or self.run_hidden):
            return False
        self.busy = True
        self.runs += 1

        def _done(res: Any, err: Optional[BaseException]) -> None:
            self.busy = False
            self.apply(res, err)

        run_async(lambda: self.collect(vis), _done)
        return True

    def _tick(self) -> bool:
        self.kick()
        return True
