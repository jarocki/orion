"""Multi-instance Zeek ingest regression tests; no Zeek/systemd required.

A synchronous tailer double makes lifecycle and cursor assertions deterministic;
real discovery, reconciliation, TSV decoding and ingest callbacks are exercised.
"""

import importlib.util
import threading
import time
from importlib.machinery import SourceFileLoader
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[2]
LOADER = SourceFileLoader("postured_multi_ingest", str(ROOT / "scripts/awareness/orionx-postured"))
SPEC = importlib.util.spec_from_loader(LOADER.name, LOADER)
PD = importlib.util.module_from_spec(SPEC)
LOADER.exec_module(PD)


class Tailer:
    """Tail at EOF, with explicit polling/reopening and observable lifecycle."""

    def __init__(self, path, on_line=None, poll=1.0, on_open=None):
        self.path = Path(path)
        self.on_line = on_line
        self.on_open = on_open
        self.starts = 0
        self.stops = 0
        self.offset = 0

    def start(self):
        self.starts += 1
        self.reopen()

    def reopen(self):
        if self.on_open:
            self.on_open(self.path)
        self.offset = self.path.stat().st_size

    def stop(self):
        self.stops += 1

    def poll_lines(self):
        assert not self.stops
        with self.path.open(encoding="utf-8") as fh:
            fh.seek(self.offset)
            for line in fh:
                self.on_line(line)
            self.offset = fh.tell()


@pytest.fixture
def tailers(monkeypatch):
    monkeypatch.setattr(PD, "LogTailer", Tailer)


def log(directory, name, fields):
    directory.mkdir(parents=True, exist_ok=True)
    path = directory / name
    path.write_text("#fields\t" + "\t".join(fields) + "\n", encoding="utf-8")
    return path


def append(path, line):
    with path.open("a", encoding="utf-8") as fh:
        fh.write(line + "\n")


def by_path(ingest):
    return {tailer.path: tailer for tailer in ingest._tailers.values()}


def ingest_for(dirs, **callbacks):
    return PD.ZeekIngest(bin_candidates=(), use_path=False, log_dirs=dirs, **callbacks)


def test_discovery_collects_all_sources_and_excludes_archive(tmp_path):
    root = tmp_path / "zeek"
    paths = [log(root / iface, "conn.log", ["uid"]) for iface in ("eth0", "wlan0")]
    log(root / "archive", "conn.log", ["uid"])
    expanded = PD.expand_zeek_log_dirs([root], instance_root=root)
    assert expanded == (root / "eth0", root / "wlan0", root)
    state = PD.detect_zeek((), expanded, use_path=False)
    assert state["usable"]
    assert state["log_dirs"] == [str(path.parent) for path in paths]
    assert state["log_dir"] == str(paths[0].parent)  # legacy status consumer
    assert set(state["log_files"]) == {str(path) for path in paths}


def test_explicit_directories_do_not_discover_unlisted_siblings(tmp_path):
    chosen = log(tmp_path / "eth0", "conn.log", ["uid"])
    log(tmp_path / "wlan0", "notice.log", ["note"])
    state = PD.detect_zeek((), [chosen.parent, chosen.parent], use_path=False)
    assert state["log_dirs"] == [str(chosen.parent)]
    assert state["log_files"] == [str(chosen)]


def test_each_interface_delivers_notice_weird_and_conn(tmp_path, tailers):
    notices, weirds, conns = [], [], []
    dirs = [tmp_path / "eth0", tmp_path / "wlan0"]
    for directory in dirs:
        log(directory, "notice.log", ["note", "src"])
        log(directory, "weird.log", ["name", "id.orig_h"])
        log(directory, "conn.log", ["uid"])
    ingest = ingest_for(dirs, on_notice=notices.append,
                        on_weird=lambda *event: weirds.append(event), on_conn=conns.append)
    assert ingest.sync()
    assert len(by_path(ingest)) == 6
    for index, directory in enumerate(dirs):
        append(directory / "notice.log", f"SSH::Password_Guessing\t192.0.2.{index + 1}")
        append(directory / "weird.log", f"bad_{index}\t192.0.2.{index + 1}")
        append(directory / "conn.log", f"C{index}")
    for tailer in by_path(ingest).values():
        tailer.poll_lines()
    assert {alert["src_ip"] for alert in notices} == {"192.0.2.1", "192.0.2.2"}
    assert set(weirds) == {("bad_0", "192.0.2.1"), ("bad_1", "192.0.2.2")}
    assert {record["uid"] for record in conns} == {"C0", "C1"}
    assert (ingest.notices_read, ingest.weird_read, ingest.conn_records) == (2, 2, 2)
    ingest.stop()


def test_stale_first_directory_does_not_hide_active_interface(tmp_path, tailers):
    stale = log(tmp_path / "eth0", "conn.log", ["uid"])
    active = log(tmp_path / "wlan0", "conn.log", ["uid"])
    append(stale, "old-connection")
    records = []
    ingest = ingest_for([stale.parent, active.parent], on_conn=records.append)
    assert ingest.sync()
    append(active, "live-connection")
    assert ingest.sync()
    for tailer in by_path(ingest).values():
        tailer.poll_lines()
    assert records == [{"uid": "live-connection"}]
    assert set(ingest.status()["log_dirs"]) == {str(stale.parent), str(active.parent)}
    ingest.stop()


def test_reconcile_new_interface_and_late_log_without_resetting_offsets(tmp_path, tailers):
    first = log(tmp_path / "eth0", "conn.log", ["uid"])
    second_dir = tmp_path / "wlan0"
    records = []
    ingest = ingest_for([first.parent, second_dir], on_conn=records.append)
    assert ingest.sync()
    original = by_path(ingest)[first]
    append(first, "queued-before-sync")
    second = log(second_dir, "conn.log", ["uid"])
    assert ingest.sync()
    assert by_path(ingest)[first] is original
    assert original.starts == 1 and original.stops == 0
    original.poll_lines()
    assert records == [{"uid": "queued-before-sync"}]
    late = log(first.parent, "notice.log", ["note"])
    assert ingest.sync()
    assert set(by_path(ingest)) == {first, second, late}
    assert by_path(ingest)[first] is original
    second_tailer = by_path(ingest)[second]
    second.unlink()
    assert ingest.sync()
    assert second_tailer.stops == 1
    assert by_path(ingest)[first] is original
    assert ingest.sync()  # repeated reconciliation is a no-op
    assert original.starts == 1
    ingest.stop()
    assert original.stops == 1
    assert not ingest.running


def test_tsv_headers_and_rotation_are_scoped_to_full_path(tmp_path, tailers):
    first = log(tmp_path / "eth0", "notice.log", ["note", "src"])
    second = log(tmp_path / "wlan0", "notice.log", ["src", "note"])
    notices = []
    ingest = ingest_for([first.parent, second.parent], on_notice=notices.append)
    assert ingest.sync()
    attached = by_path(ingest)
    append(first, "SSH::Password_Guessing\t192.0.2.1")
    append(second, "192.0.2.2\tFTP::Bruteforcing")
    attached[first].poll_lines()
    attached[second].poll_lines()
    assert [(event["note"], event["src_ip"]) for event in notices] == [
        ("SSH::Password_Guessing", "192.0.2.1"), ("FTP::Bruteforcing", "192.0.2.2")]
    first.rename(first.with_suffix(".old"))
    log(first.parent, "notice.log", ["src", "msg", "note"])
    attached[first].reopen()  # LogTailer's real rotation callback contract
    append(first, "192.0.2.3\trotated\tFTP::Bruteforcing")
    append(second, "192.0.2.4\tSSH::Password_Guessing")
    attached[first].poll_lines()
    attached[second].poll_lines()
    assert [(event["note"], event["src_ip"]) for event in notices[-2:]] == [
        ("FTP::Bruteforcing", "192.0.2.3"), ("SSH::Password_Guessing", "192.0.2.4")]
    assert notices[-2]["msg"] == "rotated"
    assert notices[-1]["msg"] == ""
    ingest.stop()


def test_current_symlink_does_not_duplicate_instance_events(tmp_path, tailers):
    physical = log(tmp_path / "eth0", "conn.log", ["uid"])
    alias = tmp_path / "current"
    alias.symlink_to(physical.parent, target_is_directory=True)
    records = []
    ingest = ingest_for([alias, physical.parent], on_conn=records.append)
    assert ingest.sync()
    assert len(by_path(ingest)) == 1
    append(physical, "one-event")
    for tailer in by_path(ingest).values():
        tailer.poll_lines()
    assert records == [{"uid": "one-event"}]
    ingest.stop()


def test_last_source_removed_stops_ingest_and_can_reappear(tmp_path, tailers):
    path = log(tmp_path / "eth0", "conn.log", ["uid"])
    ingest = ingest_for([path.parent])
    assert ingest.sync()
    original = by_path(ingest)[path]
    initial_fingerprint = ingest.state_fingerprint()
    path.unlink()
    assert not ingest.sync()
    assert original.stops == 1
    assert not ingest.running
    assert not by_path(ingest)
    assert ingest.state_fingerprint() != initial_fingerprint
    log(path.parent, "conn.log", ["uid"])
    assert ingest.sync()
    assert by_path(ingest)[path] is not original
    ingest.stop()


def test_real_tail_threads_ingest_both_interfaces(tmp_path):
    """Exercise actual LogTailer threads against files, not live Zeek traffic."""
    paths = [log(tmp_path / iface, "conn.log", ["uid"])
             for iface in ("eth0", "wlan0")]
    ready, complete = threading.Event(), threading.Event()
    seen_ready, delivered = set(), []
    lock = threading.Lock()

    def receive(record):
        uid = record["uid"]
        with lock:
            if uid.startswith("ready-"):
                seen_ready.add(uid)
                if seen_ready == {"ready-0", "ready-1"}:
                    ready.set()
            else:
                delivered.append(uid)
                if len(delivered) >= 2:
                    complete.set()

    ingest = PD.ZeekIngest(bin_candidates=(), use_path=False,
                           log_dirs=[path.parent for path in paths],
                           poll=0.01, on_conn=receive)
    threads = []
    try:
        assert ingest.sync()
        threads = [tailer._thread for tailer in ingest._tailers.values()]
        assert len(threads) == 2
        # on_open precedes seek-to-EOF, so it alone is not a readiness barrier.
        # Observe a row from BOTH real tail loops before appending test events.
        deadline = time.monotonic() + 5.0
        while not ready.is_set() and time.monotonic() < deadline:
            for index, path in enumerate(paths):
                append(path, f"ready-{index}")
            ready.wait(0.02)
        assert ready.is_set(), "both tail threads must consume readiness rows"
        for index, path in enumerate(paths):
            append(path, f"event-{index}")
        assert complete.wait(5.0), "both interface events must reach callbacks"
        with lock:
            assert sorted(delivered) == ["event-0", "event-1"]
        assert all(tailer.callback_errors == 0 for tailer in ingest._tailers.values())
    finally:
        ingest.stop()
        for thread in threads:
            thread.join(timeout=2.0)
        assert all(not thread.is_alive() for thread in threads)
