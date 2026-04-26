"""
Unit tests for scripts/storyboard-gen.py — Storyboard Generator.

Tests cover the core data structures (TimelineEvent, Timeline), all timestamp
parsing formats, each log-file parser (generic, CSV, JSON, XML), the
auto-detection dispatcher (parse_log_file), and both report generators (HTML,
text).

All tests run against real sample data in data/samples/logs/ — no mocks of
internal modules.

@decision DEC-FORENSIC-001
@title Test pure logic functions without mocking subprocess
@status accepted
@rationale storyboard-gen.py is pure Python with no subprocess calls.  Testing
  against real sample files exercises the actual parsing and report-generation
  code paths.  The only workaround is patching the module-level
  logging.FileHandler that targets /var/log (not writable in CI/dev).
"""

import datetime
import importlib.util
import json
import logging
import os
import sys
import tempfile
import unittest

# ---------------------------------------------------------------------------
# Import strategy
# ---------------------------------------------------------------------------
# storyboard-gen.py has a hyphen in the filename and configures a FileHandler
# to /var/log/orionx/ at module scope.  We must:
#   1. Use importlib (hyphen prevents normal import).
#   2. Patch logging.FileHandler before exec_module so the import doesn't
#      fail on machines without /var/log/orionx/.
# ---------------------------------------------------------------------------

_WORKTREE = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
_SCRIPT_PATH = os.path.join(_WORKTREE, "scripts", "storyboard-gen.py")

# Save original FileHandler and replace with a no-op for import
_OrigFileHandler = logging.FileHandler


class _NullFileHandler(logging.Handler):
    """Drop-in replacement so module-level basicConfig() succeeds."""

    def __init__(self, *args, **kwargs):
        super().__init__()

    def emit(self, record):
        pass


logging.FileHandler = _NullFileHandler  # type: ignore[misc]

spec = importlib.util.spec_from_file_location("storyboard_gen", _SCRIPT_PATH)
storyboard = importlib.util.module_from_spec(spec)
spec.loader.exec_module(storyboard)

# Restore real FileHandler so the rest of the process is unaffected
logging.FileHandler = _OrigFileHandler  # type: ignore[misc]

# ---------------------------------------------------------------------------
# Sample data paths
# ---------------------------------------------------------------------------
SAMPLES_DIR = os.path.join(_WORKTREE, "data", "samples")
SYSLOG = os.path.join(SAMPLES_DIR, "logs", "synthetic-syslog.log")
CSV_LOG = os.path.join(SAMPLES_DIR, "logs", "synthetic-events.csv")
JSON_LOG = os.path.join(SAMPLES_DIR, "logs", "synthetic-events.json")
XML_LOG = os.path.join(SAMPLES_DIR, "logs", "synthetic-events.xml")


# ===================================================================
# 1. parse_timestamp
# ===================================================================
class TestParseTimestamp(unittest.TestCase):
    """Exercise every format branch in parse_timestamp()."""

    def test_iso8601_space(self):
        result = storyboard.parse_timestamp("2025-01-15 08:23:01")
        self.assertEqual(result, datetime.datetime(2025, 1, 15, 8, 23, 1))

    def test_iso8601_t_separator(self):
        result = storyboard.parse_timestamp("2025-01-15T08:23:01")
        self.assertEqual(result, datetime.datetime(2025, 1, 15, 8, 23, 1))

    def test_slash_format(self):
        result = storyboard.parse_timestamp("2025/01/15 08:23:01")
        self.assertEqual(result, datetime.datetime(2025, 1, 15, 8, 23, 1))

    def test_apache_format(self):
        result = storyboard.parse_timestamp("15/Jan/2025:08:23:01")
        self.assertEqual(result, datetime.datetime(2025, 1, 15, 8, 23, 1))

    def test_syslog_format(self):
        """Syslog timestamps lack a year — parse_timestamp returns year 1900."""
        result = storyboard.parse_timestamp("Jan 15 08:23:01")
        self.assertEqual(result.month, 1)
        self.assertEqual(result.day, 15)
        self.assertEqual(result.hour, 8)
        self.assertEqual(result.minute, 23)
        self.assertEqual(result.second, 1)

    def test_generic_datetime(self):
        result = storyboard.parse_timestamp("15 Jan 2025 08:23:01")
        self.assertEqual(result, datetime.datetime(2025, 1, 15, 8, 23, 1))

    def test_embedded_timestamp_extracted(self):
        """A string with extra text around an ISO timestamp should still parse."""
        result = storyboard.parse_timestamp("prefix 2025-01-15 08:23:01 suffix")
        self.assertEqual(result, datetime.datetime(2025, 1, 15, 8, 23, 1))

    def test_unparseable_returns_now(self):
        """Totally unparseable text falls back to datetime.now()."""
        before = datetime.datetime.now()
        result = storyboard.parse_timestamp("not-a-timestamp-at-all")
        after = datetime.datetime.now()
        # The fallback is datetime.now() — result should be between before and after
        self.assertGreaterEqual(result, before)
        self.assertLessEqual(result, after)


# ===================================================================
# 2. TimelineEvent
# ===================================================================
class TestTimelineEvent(unittest.TestCase):

    def _make_event(self, **overrides):
        defaults = dict(
            timestamp=datetime.datetime(2025, 1, 15, 8, 23, 1),
            source="sshd",
            description="Accepted publickey for admin",
            severity="INFO",
            artifact_path="/var/log/auth.log",
        )
        defaults.update(overrides)
        return storyboard.TimelineEvent(**defaults)

    def test_construction(self):
        evt = self._make_event()
        self.assertEqual(evt.source, "sshd")
        self.assertEqual(evt.description, "Accepted publickey for admin")
        self.assertEqual(evt.severity, "info")  # normalized to lower
        self.assertEqual(evt.artifact_path, "/var/log/auth.log")

    def test_severity_normalized_to_lower(self):
        evt = self._make_event(severity="WARNING")
        self.assertEqual(evt.severity, "warning")

    def test_lt_comparison(self):
        early = self._make_event(timestamp=datetime.datetime(2025, 1, 15, 8, 0, 0))
        late = self._make_event(timestamp=datetime.datetime(2025, 1, 15, 9, 0, 0))
        self.assertTrue(early < late)
        self.assertFalse(late < early)

    def test_to_dict(self):
        evt = self._make_event()
        d = evt.to_dict()
        self.assertIsInstance(d, dict)
        self.assertEqual(d["timestamp"], "2025-01-15 08:23:01")
        self.assertEqual(d["source"], "sshd")
        self.assertEqual(d["description"], "Accepted publickey for admin")
        self.assertEqual(d["severity"], "info")
        self.assertEqual(d["artifact_path"], "/var/log/auth.log")

    def test_repr_contains_class_name(self):
        """__repr__ is inherited from object — just confirm it doesn't crash."""
        evt = self._make_event()
        r = repr(evt)
        self.assertIn("TimelineEvent", r)


# ===================================================================
# 3. Timeline
# ===================================================================
class TestTimeline(unittest.TestCase):

    def _make_event(self, ts, desc="evt"):
        return storyboard.TimelineEvent(
            timestamp=ts, source="test", description=desc, severity="info"
        )

    def test_add_event_and_count(self):
        tl = storyboard.Timeline()
        self.assertEqual(len(tl.events), 0)
        tl.add_event(self._make_event(datetime.datetime(2025, 1, 15, 8, 0, 0)))
        self.assertEqual(len(tl.events), 1)

    def test_sort_events(self):
        tl = storyboard.Timeline()
        tl.add_event(self._make_event(datetime.datetime(2025, 1, 15, 10, 0, 0), "late"))
        tl.add_event(self._make_event(datetime.datetime(2025, 1, 15, 8, 0, 0), "early"))
        tl.sort_events()
        self.assertEqual(tl.events[0].description, "early")
        self.assertEqual(tl.events[1].description, "late")

    def test_to_dict(self):
        tl = storyboard.Timeline()
        tl.add_event(self._make_event(datetime.datetime(2025, 1, 15, 8, 0, 0)))
        d = tl.to_dict()
        self.assertIsInstance(d, list)
        self.assertEqual(len(d), 1)
        self.assertIn("timestamp", d[0])

    def test_to_json(self):
        tl = storyboard.Timeline()
        tl.add_event(self._make_event(datetime.datetime(2025, 1, 15, 8, 0, 0)))
        j = tl.to_json()
        parsed = json.loads(j)
        self.assertIsInstance(parsed, list)
        self.assertEqual(len(parsed), 1)


# ===================================================================
# 4. parse_generic_log  (syslog sample)
# ===================================================================
class TestParseGenericLog(unittest.TestCase):

    def test_returns_events_from_syslog(self):
        events = storyboard.parse_generic_log(SYSLOG, "syslog-test")
        self.assertIsInstance(events, list)
        self.assertGreater(len(events), 0)

    def test_events_are_timeline_events(self):
        events = storyboard.parse_generic_log(SYSLOG, "syslog-test")
        for evt in events:
            self.assertIsInstance(evt, storyboard.TimelineEvent)

    def test_severity_detected(self):
        """The syslog contains 'Failed password' lines — should detect as error."""
        events = storyboard.parse_generic_log(SYSLOG, "syslog-test")
        severities = {evt.severity for evt in events}
        self.assertIn("error", severities)

    def test_source_name_propagated(self):
        events = storyboard.parse_generic_log(SYSLOG, "my-source")
        for evt in events:
            self.assertEqual(evt.source, "my-source")

    def test_all_lines_parsed(self):
        """synthetic-syslog.log has 15 non-blank lines."""
        events = storyboard.parse_generic_log(SYSLOG, "syslog-test")
        self.assertEqual(len(events), 15)


# ===================================================================
# 5. parse_csv_log
# ===================================================================
class TestParseCsvLog(unittest.TestCase):

    def test_returns_events_from_csv(self):
        events = storyboard.parse_csv_log(CSV_LOG, "csv-test")
        self.assertIsInstance(events, list)
        self.assertGreater(len(events), 0)

    def test_correct_event_count(self):
        """synthetic-events.csv has 7 data rows (header excluded)."""
        events = storyboard.parse_csv_log(CSV_LOG, "csv-test")
        self.assertEqual(len(events), 7)

    def test_timestamps_parsed(self):
        events = storyboard.parse_csv_log(CSV_LOG, "csv-test")
        for evt in events:
            self.assertIsInstance(evt.timestamp, datetime.datetime)

    def test_severity_mapping(self):
        """CSV has ERROR and CRITICAL rows — should map to 'error'."""
        events = storyboard.parse_csv_log(CSV_LOG, "csv-test")
        severities = {evt.severity for evt in events}
        self.assertIn("error", severities)

    def test_description_populated(self):
        events = storyboard.parse_csv_log(CSV_LOG, "csv-test")
        for evt in events:
            self.assertTrue(len(evt.description) > 0)


# ===================================================================
# 6. parse_json_log
# ===================================================================
class TestParseJsonLog(unittest.TestCase):

    def test_returns_events_from_json(self):
        events = storyboard.parse_json_log(JSON_LOG, "json-test")
        self.assertIsInstance(events, list)
        self.assertGreater(len(events), 0)

    def test_correct_event_count(self):
        """synthetic-events.json has 7 entries."""
        events = storyboard.parse_json_log(JSON_LOG, "json-test")
        self.assertEqual(len(events), 7)

    def test_message_field_used(self):
        """JSON entries have a 'message' field — description should contain it."""
        events = storyboard.parse_json_log(JSON_LOG, "json-test")
        descs = [evt.description for evt in events]
        self.assertTrue(any("publickey" in d for d in descs))

    def test_severity_parsed(self):
        events = storyboard.parse_json_log(JSON_LOG, "json-test")
        severities = {evt.severity for evt in events}
        self.assertIn("error", severities)


# ===================================================================
# 7. parse_xml_log
# ===================================================================
class TestParseXmlLog(unittest.TestCase):

    def test_returns_events_from_xml(self):
        events = storyboard.parse_xml_log(XML_LOG, "xml-test")
        self.assertIsInstance(events, list)
        self.assertGreater(len(events), 0)

    def test_correct_event_count(self):
        """synthetic-events.xml has 7 <event> elements."""
        events = storyboard.parse_xml_log(XML_LOG, "xml-test")
        self.assertEqual(len(events), 7)

    def test_timestamps_parsed(self):
        events = storyboard.parse_xml_log(XML_LOG, "xml-test")
        for evt in events:
            self.assertIsInstance(evt.timestamp, datetime.datetime)

    def test_description_populated(self):
        events = storyboard.parse_xml_log(XML_LOG, "xml-test")
        for evt in events:
            self.assertTrue(len(evt.description) > 0)


# ===================================================================
# 8. parse_log_file  (auto-detection dispatch)
# ===================================================================
class TestParseLogFile(unittest.TestCase):

    def test_csv_dispatched(self):
        events = storyboard.parse_log_file(CSV_LOG)
        self.assertEqual(len(events), 7)

    def test_json_dispatched(self):
        events = storyboard.parse_log_file(JSON_LOG)
        self.assertEqual(len(events), 7)

    def test_xml_dispatched(self):
        events = storyboard.parse_log_file(XML_LOG)
        self.assertEqual(len(events), 7)

    def test_generic_dispatched(self):
        events = storyboard.parse_log_file(SYSLOG)
        self.assertEqual(len(events), 15)

    def test_missing_file_returns_empty(self):
        events = storyboard.parse_log_file("/nonexistent/path/fake.log")
        self.assertEqual(events, [])

    def test_source_name_defaults_to_basename(self):
        events = storyboard.parse_log_file(CSV_LOG)
        for evt in events:
            self.assertEqual(evt.source, "synthetic-events.csv")


# ===================================================================
# 9. generate_html_report
# ===================================================================
class TestGenerateHtmlReport(unittest.TestCase):

    def setUp(self):
        self.timeline = storyboard.Timeline()
        self.timeline.add_event(storyboard.TimelineEvent(
            timestamp=datetime.datetime(2025, 1, 15, 8, 23, 1),
            source="sshd",
            description="Accepted publickey for admin",
            severity="INFO",
        ))
        self.timeline.add_event(storyboard.TimelineEvent(
            timestamp=datetime.datetime(2025, 1, 15, 8, 31, 45),
            source="sshd",
            description="Failed password for root",
            severity="ERROR",
        ))
        self.case_info = {
            "case_name": "Test Incident",
            "case_id": "TEST-001",
            "analyst": "unit-test",
        }
        fd, self.output_path = tempfile.mkstemp(suffix=".html")
        os.close(fd)

    def tearDown(self):
        if os.path.exists(self.output_path):
            os.unlink(self.output_path)

    def test_html_file_created(self):
        result = storyboard.generate_html_report(
            self.timeline, self.case_info, self.output_path
        )
        self.assertTrue(result)
        self.assertTrue(os.path.exists(self.output_path))

    def test_html_contains_doctype(self):
        storyboard.generate_html_report(
            self.timeline, self.case_info, self.output_path
        )
        with open(self.output_path) as f:
            html = f.read()
        self.assertIn("<!DOCTYPE html>", html)

    def test_html_contains_html_tag(self):
        storyboard.generate_html_report(
            self.timeline, self.case_info, self.output_path
        )
        with open(self.output_path) as f:
            html = f.read()
        self.assertIn("<html", html.lower())

    def test_html_contains_event_data(self):
        storyboard.generate_html_report(
            self.timeline, self.case_info, self.output_path
        )
        with open(self.output_path) as f:
            html = f.read()
        self.assertIn("admin", html)
        self.assertIn("Failed password", html)

    def test_html_contains_severity_css(self):
        storyboard.generate_html_report(
            self.timeline, self.case_info, self.output_path
        )
        with open(self.output_path) as f:
            html = f.read()
        # The CSS uses classes .error, .warning, .info for severity styling
        self.assertIn(".error", html)
        self.assertIn(".warning", html)
        self.assertIn(".info", html)

    def test_html_contains_case_info(self):
        storyboard.generate_html_report(
            self.timeline, self.case_info, self.output_path
        )
        with open(self.output_path) as f:
            html = f.read()
        self.assertIn("Test Incident", html)
        self.assertIn("TEST-001", html)

    def test_empty_timeline(self):
        """An empty timeline should still produce a valid HTML file."""
        empty_tl = storyboard.Timeline()
        result = storyboard.generate_html_report(
            empty_tl, self.case_info, self.output_path
        )
        self.assertTrue(result)
        with open(self.output_path) as f:
            html = f.read()
        self.assertIn("<html", html.lower())
        self.assertIn("N/A", html)  # date_range falls back to N/A


# ===================================================================
# 10. generate_text_report
# ===================================================================
class TestGenerateTextReport(unittest.TestCase):

    def setUp(self):
        self.timeline = storyboard.Timeline()
        self.timeline.add_event(storyboard.TimelineEvent(
            timestamp=datetime.datetime(2025, 1, 15, 8, 23, 1),
            source="sshd",
            description="Accepted publickey for admin",
            severity="INFO",
        ))
        self.timeline.add_event(storyboard.TimelineEvent(
            timestamp=datetime.datetime(2025, 1, 15, 8, 31, 45),
            source="sshd",
            description="Failed password for root",
            severity="ERROR",
        ))
        self.case_info = {
            "case_name": "Test Incident",
            "case_id": "TEST-001",
            "analyst": "unit-test",
        }
        fd, self.output_path = tempfile.mkstemp(suffix=".txt")
        os.close(fd)

    def tearDown(self):
        if os.path.exists(self.output_path):
            os.unlink(self.output_path)

    def test_text_file_created(self):
        result = storyboard.generate_text_report(
            self.timeline, self.case_info, self.output_path
        )
        self.assertTrue(result)
        self.assertTrue(os.path.exists(self.output_path))

    def test_text_contains_header(self):
        storyboard.generate_text_report(
            self.timeline, self.case_info, self.output_path
        )
        with open(self.output_path) as f:
            text = f.read()
        self.assertIn("INCIDENT TIMELINE", text)
        self.assertIn("Test Incident", text)

    def test_text_contains_case_info(self):
        storyboard.generate_text_report(
            self.timeline, self.case_info, self.output_path
        )
        with open(self.output_path) as f:
            text = f.read()
        self.assertIn("Case ID: TEST-001", text)
        self.assertIn("Analyst: unit-test", text)

    def test_text_contains_timeline_entries(self):
        storyboard.generate_text_report(
            self.timeline, self.case_info, self.output_path
        )
        with open(self.output_path) as f:
            text = f.read()
        self.assertIn("admin", text)
        self.assertIn("Failed password", text)
        self.assertIn("[ERROR]", text)
        self.assertIn("[INFO]", text)

    def test_text_contains_severity_in_brackets(self):
        storyboard.generate_text_report(
            self.timeline, self.case_info, self.output_path
        )
        with open(self.output_path) as f:
            text = f.read()
        self.assertIn("[ERROR]", text)

    def test_empty_timeline(self):
        empty_tl = storyboard.Timeline()
        result = storyboard.generate_text_report(
            empty_tl, self.case_info, self.output_path
        )
        self.assertTrue(result)
        with open(self.output_path) as f:
            text = f.read()
        self.assertIn("Total Events: 0", text)


# ===================================================================
# 11. End-to-end production sequence
# ===================================================================
class TestEndToEndProductionSequence(unittest.TestCase):
    """
    Production sequence: analyst invokes storyboard-gen with a directory
    containing mixed log formats.  parse_log_file auto-detects each format,
    events are aggregated into a Timeline, sorted, and rendered.

    This test exercises the full pipeline with all four sample files.
    """

    def test_full_pipeline_all_formats(self):
        tl = storyboard.Timeline()

        for log_path in (SYSLOG, CSV_LOG, JSON_LOG, XML_LOG):
            events = storyboard.parse_log_file(log_path)
            for evt in events:
                tl.add_event(evt)

        # 15 syslog + 7 CSV + 7 JSON + 7 XML = 36 total
        self.assertEqual(len(tl.events), 36)

        tl.sort_events()
        # After sort, first event should be earliest
        # All non-syslog files start at 2025-01-15T08:23:01
        self.assertEqual(tl.events[0].timestamp.month, 1)
        self.assertEqual(tl.events[0].timestamp.day, 15)

        # Generate both report types
        fd_html, html_path = tempfile.mkstemp(suffix=".html")
        os.close(fd_html)
        fd_txt, txt_path = tempfile.mkstemp(suffix=".txt")
        os.close(fd_txt)

        case_info = {"case_name": "E2E", "case_id": "E2E-001", "analyst": "auto"}

        try:
            self.assertTrue(
                storyboard.generate_html_report(tl, case_info, html_path)
            )
            self.assertTrue(
                storyboard.generate_text_report(tl, case_info, txt_path)
            )

            with open(html_path) as f:
                html = f.read()
            self.assertIn("<!DOCTYPE html>", html)
            self.assertIn("36", html)  # event_count in the report

            with open(txt_path) as f:
                text = f.read()
            self.assertIn("Total Events: 36", text)
        finally:
            os.unlink(html_path)
            os.unlink(txt_path)

    def test_json_serialization_roundtrip(self):
        """Timeline can be serialized to JSON and the result is valid."""
        tl = storyboard.Timeline()
        events = storyboard.parse_log_file(CSV_LOG)
        for evt in events:
            tl.add_event(evt)

        j = tl.to_json()
        parsed = json.loads(j)
        self.assertEqual(len(parsed), 7)
        for entry in parsed:
            self.assertIn("timestamp", entry)
            self.assertIn("description", entry)
            self.assertIn("severity", entry)


if __name__ == "__main__":
    unittest.main()
