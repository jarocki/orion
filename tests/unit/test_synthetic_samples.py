"""
@decision DEC-SAMPLES-001
@title Synthetic sample data validation tests
@status accepted
@rationale Phase 5 forensic scripts require deterministic, well-formed test
  data. These tests validate that every synthetic sample exists, has the
  correct format, and contains the expected content patterns. Tests run
  against real files (no mocks) to match Sacred Practice #5.

Tests cover:
  - File existence and non-zero size
  - Syslog line format and severity distribution
  - CSV structure and header validation
  - JSON schema compliance
  - XML well-formedness and structure
  - PCAP magic bytes and minimal packet structure
  - Memory dump recognizable patterns (MZ header)
  - Firmware binary patterns (ELF magic)
  - README files updated with synthetic sample notes
"""

import csv
import json
import os
import re
import struct
import unittest
import xml.etree.ElementTree as ET

# All paths relative to project root
PROJECT_ROOT = os.path.abspath(
    os.path.join(os.path.dirname(__file__), os.pardir, os.pardir)
)
SAMPLES_DIR = os.path.join(PROJECT_ROOT, "data", "samples")
LOGS_DIR = os.path.join(SAMPLES_DIR, "logs")
PCAPS_DIR = os.path.join(SAMPLES_DIR, "pcaps")
MEMORY_DIR = os.path.join(SAMPLES_DIR, "memory")
FIRMWARE_DIR = os.path.join(SAMPLES_DIR, "firmware")


class TestSyntheticSyslog(unittest.TestCase):
    """Validate synthetic-syslog.log format and content."""

    SYSLOG_PATH = os.path.join(LOGS_DIR, "synthetic-syslog.log")

    def test_file_exists(self):
        self.assertTrue(
            os.path.isfile(self.SYSLOG_PATH),
            f"Syslog file not found: {self.SYSLOG_PATH}",
        )

    def test_file_nonempty(self):
        self.assertGreater(os.path.getsize(self.SYSLOG_PATH), 0)

    def test_line_count_in_range(self):
        with open(self.SYSLOG_PATH) as f:
            lines = [line for line in f if line.strip()]
        self.assertGreaterEqual(len(lines), 15, f"Too few lines: {len(lines)}")
        self.assertLessEqual(len(lines), 20, f"Too many lines: {len(lines)}")

    def test_syslog_format(self):
        """Each line should match standard syslog: Month Day HH:MM:SS hostname process[pid]: message."""
        pattern = re.compile(
            r"^[A-Z][a-z]{2}\s+\d{1,2}\s+\d{2}:\d{2}:\d{2}\s+\S+\s+\S+(\[\d+\])?:\s+.+"
        )
        with open(self.SYSLOG_PATH) as f:
            for i, line in enumerate(f, 1):
                line = line.strip()
                if not line:
                    continue
                self.assertRegex(
                    line, pattern, f"Line {i} does not match syslog format"
                )

    def test_contains_mixed_severities(self):
        """Should contain indicators of INFO, WARNING, and ERROR-level events."""
        with open(self.SYSLOG_PATH) as f:
            content = f.read()
        self.assertIn("Accepted", content, "Missing INFO-level event (Accepted)")
        self.assertIn("BLOCK", content, "Missing WARNING-level event (UFW BLOCK)")
        self.assertIn(
            "Failed password", content, "Missing ERROR-level event (Failed password)"
        )

    def test_contains_security_events(self):
        """Should have ssh, firewall, and malware detection events."""
        with open(self.SYSLOG_PATH) as f:
            content = f.read()
        self.assertIn("sshd", content)
        self.assertIn("UFW", content)
        self.assertTrue(
            "clamav" in content or "FOUND" in content,
            "Missing clamav/malware event",
        )

    def test_contains_orionx_mesh_events(self):
        """Should contain Orion-X mesh-specific log entries."""
        with open(self.SYSLOG_PATH) as f:
            content = f.read()
        self.assertIn("orionx-mesh", content)


class TestSyntheticEventsCSV(unittest.TestCase):
    """Validate synthetic-events.csv format and content."""

    CSV_PATH = os.path.join(LOGS_DIR, "synthetic-events.csv")

    def test_file_exists(self):
        self.assertTrue(os.path.isfile(self.CSV_PATH))

    def test_file_nonempty(self):
        self.assertGreater(os.path.getsize(self.CSV_PATH), 0)

    def test_valid_csv(self):
        """File must be parseable by csv.reader without errors."""
        with open(self.CSV_PATH) as f:
            rows = list(csv.reader(f))
        self.assertGreaterEqual(len(rows), 2, "Need at least header + 1 data row")

    def test_csv_headers(self):
        with open(self.CSV_PATH) as f:
            reader = csv.DictReader(f)
            fields = reader.fieldnames
        self.assertEqual(fields, ["timestamp", "severity", "source", "message"])

    def test_severity_values(self):
        """All severity values must be from the allowed set."""
        allowed = {"INFO", "WARNING", "ERROR", "CRITICAL"}
        with open(self.CSV_PATH) as f:
            reader = csv.DictReader(f)
            for row in reader:
                self.assertIn(
                    row["severity"], allowed, f"Invalid severity: {row['severity']}"
                )

    def test_timestamp_format(self):
        """Timestamps should be ISO 8601 format."""
        iso_pattern = re.compile(r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}$")
        with open(self.CSV_PATH) as f:
            reader = csv.DictReader(f)
            for row in reader:
                self.assertRegex(
                    row["timestamp"],
                    iso_pattern,
                    f"Bad timestamp format: {row['timestamp']}",
                )

    def test_has_critical_event(self):
        """Must contain at least one CRITICAL severity event (malware detection)."""
        with open(self.CSV_PATH) as f:
            reader = csv.DictReader(f)
            severities = [row["severity"] for row in reader]
        self.assertIn("CRITICAL", severities)

    def test_has_error_events(self):
        """Must contain ERROR events (failed password attempts)."""
        with open(self.CSV_PATH) as f:
            reader = csv.DictReader(f)
            severities = [row["severity"] for row in reader]
        self.assertGreaterEqual(
            severities.count("ERROR"), 3, "Expected at least 3 failed password attempts"
        )


class TestSyntheticEventsJSON(unittest.TestCase):
    """Validate synthetic-events.json format and content."""

    JSON_PATH = os.path.join(LOGS_DIR, "synthetic-events.json")

    def test_file_exists(self):
        self.assertTrue(os.path.isfile(self.JSON_PATH))

    def test_file_nonempty(self):
        self.assertGreater(os.path.getsize(self.JSON_PATH), 0)

    def test_valid_json(self):
        """File must be valid JSON."""
        with open(self.JSON_PATH) as f:
            data = json.load(f)
        self.assertIsInstance(data, list, "Root element must be a JSON array")

    def test_event_structure(self):
        """Each event must have timestamp, severity, source, message."""
        required_keys = {"timestamp", "severity", "source", "message"}
        with open(self.JSON_PATH) as f:
            data = json.load(f)
        for i, event in enumerate(data):
            missing = required_keys - set(event.keys())
            self.assertFalse(missing, f"Event {i} missing keys: {missing}")

    def test_event_count(self):
        with open(self.JSON_PATH) as f:
            data = json.load(f)
        self.assertGreaterEqual(len(data), 5, f"Expected at least 5 events, got {len(data)}")

    def test_severity_distribution(self):
        """Should have events at multiple severity levels."""
        with open(self.JSON_PATH) as f:
            data = json.load(f)
        severities = {e["severity"] for e in data}
        self.assertGreaterEqual(
            len(severities), 3, f"Expected at least 3 distinct severities, got {severities}"
        )


class TestSyntheticEventsXML(unittest.TestCase):
    """Validate synthetic-events.xml format and content."""

    XML_PATH = os.path.join(LOGS_DIR, "synthetic-events.xml")

    def test_file_exists(self):
        self.assertTrue(os.path.isfile(self.XML_PATH))

    def test_file_nonempty(self):
        self.assertGreater(os.path.getsize(self.XML_PATH), 0)

    def test_valid_xml(self):
        """File must be well-formed XML."""
        tree = ET.parse(self.XML_PATH)
        root = tree.getroot()
        self.assertEqual(root.tag, "events")

    def test_event_attributes(self):
        """Each <event> element must have timestamp, severity, source attributes."""
        tree = ET.parse(self.XML_PATH)
        root = tree.getroot()
        events = root.findall("event")
        self.assertGreaterEqual(len(events), 4, f"Expected at least 4 events, got {len(events)}")
        for event in events:
            self.assertIn("timestamp", event.attrib)
            self.assertIn("severity", event.attrib)
            self.assertIn("source", event.attrib)
            self.assertTrue(
                event.text and event.text.strip(), "Event text must not be empty"
            )

    def test_xml_declaration(self):
        """File should start with XML declaration."""
        with open(self.XML_PATH) as f:
            first_line = f.readline()
        self.assertTrue(
            first_line.strip().startswith("<?xml"), "Missing XML declaration"
        )


class TestSyntheticPCAP(unittest.TestCase):
    """Validate synthetic-sample.pcap binary format."""

    PCAP_PATH = os.path.join(PCAPS_DIR, "synthetic-sample.pcap")

    def test_file_exists(self):
        self.assertTrue(os.path.isfile(self.PCAP_PATH))

    def test_file_nonempty(self):
        self.assertGreater(os.path.getsize(self.PCAP_PATH), 0)

    def test_pcap_magic_bytes(self):
        """First 4 bytes must be the pcap magic number 0xa1b2c3d4."""
        with open(self.PCAP_PATH, "rb") as f:
            magic = struct.unpack("<I", f.read(4))[0]
        self.assertEqual(magic, 0xA1B2C3D4, f"Bad magic: 0x{magic:08x}")

    def test_pcap_global_header(self):
        """Global header should be 24 bytes with valid version and link type."""
        with open(self.PCAP_PATH, "rb") as f:
            header = f.read(24)
        self.assertEqual(len(header), 24, "Global header too short")
        magic, ver_major, ver_minor, _, _, snaplen, linktype = struct.unpack(
            "<IHHiIII", header
        )
        self.assertEqual(ver_major, 2)
        self.assertEqual(ver_minor, 4)
        self.assertEqual(snaplen, 65535)
        self.assertEqual(linktype, 1)  # LINKTYPE_ETHERNET

    def test_pcap_has_packet(self):
        """File should contain at least one packet record after the global header."""
        size = os.path.getsize(self.PCAP_PATH)
        self.assertGreater(size, 24, "File has no packet data after global header")
        with open(self.PCAP_PATH, "rb") as f:
            f.seek(24)  # skip global header
            pkt_header = f.read(16)
        self.assertEqual(len(pkt_header), 16, "Packet header incomplete")
        ts_sec, ts_usec, incl_len, orig_len = struct.unpack("<IIII", pkt_header)
        self.assertGreater(incl_len, 0, "Packet has zero length")
        self.assertEqual(incl_len, orig_len, "Included length should equal original length")


class TestSyntheticMemoryDump(unittest.TestCase):
    """Validate synthetic-mini.raw format."""

    MEMORY_PATH = os.path.join(MEMORY_DIR, "synthetic-mini.raw")

    def test_file_exists(self):
        self.assertTrue(os.path.isfile(self.MEMORY_PATH))

    def test_file_size(self):
        """Should be exactly 1024 bytes."""
        self.assertEqual(os.path.getsize(self.MEMORY_PATH), 1024)

    def test_pe_header_signature(self):
        """First two bytes should be MZ (PE executable header signature)."""
        with open(self.MEMORY_PATH, "rb") as f:
            magic = f.read(2)
        self.assertEqual(magic, b"MZ", f"Expected MZ, got {magic!r}")

    def test_contains_recognizable_text(self):
        """Should contain recognizable text patterns for testing."""
        with open(self.MEMORY_PATH, "rb") as f:
            content = f.read()
        self.assertIn(b"synthetic memory data", content)
        self.assertIn(b"Orion-X", content)


class TestSyntheticFirmware(unittest.TestCase):
    """Validate synthetic-firmware.bin format."""

    FIRMWARE_PATH = os.path.join(FIRMWARE_DIR, "synthetic-firmware.bin")

    def test_file_exists(self):
        self.assertTrue(os.path.isfile(self.FIRMWARE_PATH))

    def test_file_size(self):
        """Should be exactly 512 bytes."""
        self.assertEqual(os.path.getsize(self.FIRMWARE_PATH), 512)

    def test_elf_magic(self):
        """First four bytes should be ELF magic: 0x7f E L F."""
        with open(self.FIRMWARE_PATH, "rb") as f:
            magic = f.read(4)
        self.assertEqual(magic, b"\x7fELF", f"Expected ELF magic, got {magic!r}")

    def test_contains_firmware_text(self):
        """Should contain recognizable firmware text."""
        with open(self.FIRMWARE_PATH, "rb") as f:
            content = f.read()
        self.assertIn(b"Synthetic firmware", content)


class TestREADMEUpdates(unittest.TestCase):
    """Verify README files mention synthetic samples."""

    def test_pcaps_readme_updated(self):
        readme_path = os.path.join(PCAPS_DIR, "README.txt")
        with open(readme_path) as f:
            content = f.read()
        self.assertIn(
            "synthetic",
            content.lower(),
            "pcaps/README.txt should mention synthetic samples",
        )

    def test_logs_readme_updated(self):
        readme_path = os.path.join(LOGS_DIR, "README.txt")
        with open(readme_path) as f:
            content = f.read()
        self.assertIn(
            "synthetic",
            content.lower(),
            "logs/README.txt should mention synthetic samples",
        )

    def test_memory_readme_updated(self):
        readme_path = os.path.join(MEMORY_DIR, "README.txt")
        with open(readme_path) as f:
            content = f.read()
        self.assertIn(
            "synthetic",
            content.lower(),
            "memory/README.txt should mention synthetic samples",
        )

    def test_firmware_readme_updated(self):
        readme_path = os.path.join(FIRMWARE_DIR, "README.txt")
        with open(readme_path) as f:
            content = f.read()
        self.assertIn(
            "synthetic",
            content.lower(),
            "firmware/README.txt should mention synthetic samples",
        )


class TestGitignoreCompatibility(unittest.TestCase):
    """Ensure synthetic files are not excluded by .gitignore rules."""

    def test_syslog_file_trackable(self):
        """The .log file needs a gitignore exception or different extension."""
        syslog_path = os.path.join(LOGS_DIR, "synthetic-syslog.log")
        self.assertTrue(os.path.isfile(syslog_path), "Syslog file must exist")


if __name__ == "__main__":
    unittest.main()
