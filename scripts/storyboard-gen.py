#!/usr/bin/env python3
"""
Orion-X Phoenix Edition — Storyboard Generator
===============================================
Correlates log files and forensic artifacts into a chronological incident
timeline, producing an HTML or plain-text narrative report.

Usage:
    storyboard-gen.py -i <path> [<path>...] -o <output> [-f html|text]

Rationale:
    Analysts often need to correlate events across CSV, JSON, XML, and
    plain-text logs.  This script normalises timestamps, deduces severity,
    and emits a single unified timeline so the responder reads one document
    instead of many.

@decision DEC-004 [BOOTSTRAP]
@title Phase 1 bootstrap — storyboard-gen bare-except fixes
@status accepted
@rationale Three bare except: clauses replaced with typed exceptions.
           Timestamp parse failures are non-fatal fallbacks (mtime used
           instead); ValueError/Exception used where the original intent
           was catch-all fallback, keeping behaviour identical.
"""
#
# Orion-X Phoenix Edition v1.5.5
# Storyboard Generator Script
#
# This script creates a chronological "story" of an incident by correlating
# different logs and artifacts. It generates a human-readable incident narrative
# or an HTML report.

import os
import sys
import argparse
import logging
import json
import datetime
import re
from pathlib import Path
from collections import defaultdict

# Configure logging
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
    handlers=[
        logging.FileHandler("/var/log/orionx/storyboard_gen.log"),
        logging.StreamHandler(sys.stdout)
    ]
)
logger = logging.getLogger("orionx-storyboard-gen")

# Timeline event class
class TimelineEvent:
    def __init__(self, timestamp, source, description, severity="info", artifact_path=None):
        self.timestamp = timestamp
        self.source = source
        self.description = description
        self.severity = severity.lower()  # normalize severity
        self.artifact_path = artifact_path
    
    def __lt__(self, other):
        return self.timestamp < other.timestamp
    
    def to_dict(self):
        return {
            "timestamp": self.timestamp.strftime("%Y-%m-%d %H:%M:%S"),
            "source": self.source,
            "description": self.description,
            "severity": self.severity,
            "artifact_path": self.artifact_path
        }

# Timeline class
class Timeline:
    def __init__(self):
        self.events = []
    
    def add_event(self, event):
        self.events.append(event)
    
    def sort_events(self):
        self.events.sort()
    
    def to_dict(self):
        return [event.to_dict() for event in self.events]
    
    def to_json(self):
        return json.dumps(self.to_dict(), indent=2)

# Function to parse timestamp from various formats
def parse_timestamp(timestamp_str):
    # Try different timestamp formats
    formats = [
        "%Y-%m-%d %H:%M:%S",
        "%Y-%m-%dT%H:%M:%S",
        "%Y/%m/%d %H:%M:%S",
        "%d/%b/%Y:%H:%M:%S",
        "%b %d %H:%M:%S",
        "%d %b %Y %H:%M:%S"
    ]
    
    for fmt in formats:
        try:
            return datetime.datetime.strptime(timestamp_str, fmt)
        except ValueError:
            continue
    
    # If all formats fail, try to extract partial timestamp with regex
    timestamp_patterns = [
        r"(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2})",
        r"(\d{4}/\d{2}/\d{2} \d{2}:\d{2}:\d{2})",
        r"(\d{2}/[A-Za-z]{3}/\d{4}:\d{2}:\d{2}:\d{2})"
    ]
    
    for pattern in timestamp_patterns:
        match = re.search(pattern, timestamp_str)
        if match:
            return parse_timestamp(match.group(1))
    
    logger.warning(f"Could not parse timestamp: {timestamp_str}")
    return datetime.datetime.now()  # Default to current time if parsing fails

# Function to parse log file and extract events
def parse_log_file(file_path, source_name=None):
    events = []

    if not os.path.isfile(file_path):
        logger.error(f"Log file not found: {file_path}")
        return events

    if source_name is None:
        source_name = os.path.basename(file_path)

    logger.info(f"Parsing log file: {file_path}")

    # Detect log type based on extension and content
    log_type = "generic"
    file_ext = os.path.splitext(file_path)[1].lower()

    if file_ext == ".csv":
        log_type = "csv"
    elif file_ext == ".json":
        log_type = "json"
    elif file_ext == ".xml":
        log_type = "xml"
    else:
        # Check content for format clues
        with open(file_path, "r", errors="ignore") as f:
            first_line = f.readline().strip()
            if first_line.startswith("{") and first_line.endswith("}"):
                log_type = "json"
            elif first_line.startswith("<"):
                log_type = "xml"
            elif "," in first_line and len(first_line.split(",")) > 3:
                log_type = "csv"

    # Parse based on log type
    if log_type == "csv":
        events = parse_csv_log(file_path, source_name)
    elif log_type == "json":
        events = parse_json_log(file_path, source_name)
    elif log_type == "xml":
        events = parse_xml_log(file_path, source_name)
    else:
        events = parse_generic_log(file_path, source_name)

    logger.info(f"Extracted {len(events)} events from {file_path}")
    return events

# Function to parse generic text log file
def parse_generic_log(file_path, source_name):
    events = []
    severity_keywords = {
        "error": "error",
        "critical": "error",
        "fail": "error",
        "alert": "warning",
        "warning": "warning",
        "warn": "warning",
        "notice": "info",
        "info": "info"
    }

    try:
        with open(file_path, "r", errors="ignore") as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue

                # Try to extract timestamp
                timestamp = None
                timestamp_match = re.search(r"(\d{4}[-/]\d{2}[-/]\d{2}[T ]\d{2}:\d{2}:\d{2})", line)
                if timestamp_match:
                    timestamp_str = timestamp_match.group(1)
                    timestamp = parse_timestamp(timestamp_str)

                if timestamp is None:
                    # Try simpler timestamp formats
                    timestamp_match = re.search(r"(\w{3} \d{2} \d{2}:\d{2}:\d{2})", line)
                    if timestamp_match:
                        current_year = datetime.datetime.now().year
                        timestamp_str = f"{timestamp_match.group(1)} {current_year}"
                        try:
                            timestamp = datetime.datetime.strptime(timestamp_str, "%b %d %H:%M:%S %Y")
                        except ValueError:
                            timestamp = datetime.datetime.now()

                if timestamp is None:
                    # If no timestamp found, use file modification time
                    file_time = os.path.getmtime(file_path)
                    timestamp = datetime.datetime.fromtimestamp(file_time)

                # Determine severity
                severity = "info"
                for keyword, sev in severity_keywords.items():
                    if keyword in line.lower():
                        severity = sev
                        break

                # Create event
                event = TimelineEvent(
                    timestamp=timestamp,
                    source=source_name,
                    description=line,
                    severity=severity,
                    artifact_path=file_path
                )
                events.append(event)
    except Exception as e:
        logger.error(f"Error parsing generic log {file_path}: {e}")

    return events

# Function to parse CSV log file
def parse_csv_log(file_path, source_name):
    events = []
    import csv

    try:
        with open(file_path, "r", errors="ignore") as f:
            csv_reader = csv.reader(f)
            headers = next(csv_reader, None)

            # Determine timestamp column
            timestamp_col = None
            if headers:
                for i, header in enumerate(headers):
                    if any(keyword in header.lower() for keyword in ["time", "date", "timestamp"]):
                        timestamp_col = i
                        break

            if timestamp_col is None:
                timestamp_col = 0  # Default to first column

            # Determine description column
            desc_col = None
            if headers:
                for i, header in enumerate(headers):
                    if any(keyword in header.lower() for keyword in ["message", "description", "event", "log"]):
                        desc_col = i
                        break

            if desc_col is None:
                desc_col = 1 if len(headers) > 1 else 0  # Default to second column if available

            # Determine severity column
            severity_col = None
            if headers:
                for i, header in enumerate(headers):
                    if any(keyword in header.lower() for keyword in ["severity", "level", "type"]):
                        severity_col = i
                        break

            for row in csv_reader:
                if not row or len(row) <= max(timestamp_col, desc_col):
                    continue

                timestamp_str = row[timestamp_col]
                try:
                    timestamp = parse_timestamp(timestamp_str)
                except ValueError:
                    # @defprog-exempt: timestamp parse failure is non-fatal — fall back to mtime
                    file_time = os.path.getmtime(file_path)
                    timestamp = datetime.datetime.fromtimestamp(file_time)

                description = row[desc_col]

                severity = "info"
                if severity_col is not None and severity_col < len(row):
                    severity_val = row[severity_col].lower()
                    if any(keyword in severity_val for keyword in ["error", "critical", "fail"]):
                        severity = "error"
                    elif any(keyword in severity_val for keyword in ["warn", "alert"]):
                        severity = "warning"

                event = TimelineEvent(
                    timestamp=timestamp,
                    source=source_name,
                    description=description,
                    severity=severity,
                    artifact_path=file_path
                )
                events.append(event)
    except Exception as e:
        logger.error(f"Error parsing CSV log {file_path}: {e}")

    return events

# Function to parse JSON log file
def parse_json_log(file_path, source_name):
    events = []

    try:
        with open(file_path, "r", errors="ignore") as f:
            content = f.read()

            # Check if the file contains one JSON object per line
            if content.strip().startswith("[") and content.strip().endswith("]"):
                # Single JSON array
                log_entries = json.loads(content)
                if isinstance(log_entries, list):
                    for entry in log_entries:
                        events.extend(extract_events_from_json(entry, source_name, file_path))
            else:
                # Multiple JSON objects (one per line)
                for line in content.splitlines():
                    line = line.strip()
                    if not line:
                        continue
                    try:
                        entry = json.loads(line)
                        events.extend(extract_events_from_json(entry, source_name, file_path))
                    except json.JSONDecodeError:
                        continue
    except Exception as e:
        logger.error(f"Error parsing JSON log {file_path}: {e}")

    return events

# Helper function to extract events from a JSON object
def extract_events_from_json(entry, source_name, file_path):
    events = []

    # Find timestamp field
    timestamp = None
    timestamp_fields = ["timestamp", "time", "date", "@timestamp", "eventTime", "created_at"]
    for field in timestamp_fields:
        if field in entry:
            try:
                timestamp = parse_timestamp(str(entry[field]))
                break
            except ValueError:
                # @defprog-exempt: try next candidate field; ValueError from strptime is expected
                continue

    if timestamp is None:
        # If no timestamp found, use file modification time
        file_time = os.path.getmtime(file_path)
        timestamp = datetime.datetime.fromtimestamp(file_time)

    # Find message/description field
    description = None
    message_fields = ["message", "msg", "description", "desc", "event", "log"]
    for field in message_fields:
        if field in entry:
            description = str(entry[field])
            break

    if description is None:
        # If no specific message field, use the entire entry
        description = json.dumps(entry)

    # Find severity field
    severity = "info"
    severity_fields = ["severity", "level", "type", "log_level"]
    for field in severity_fields:
        if field in entry:
            severity_val = str(entry[field]).lower()
            if any(keyword in severity_val for keyword in ["error", "critical", "fail"]):
                severity = "error"
            elif any(keyword in severity_val for keyword in ["warn", "alert"]):
                severity = "warning"
            break

    event = TimelineEvent(
        timestamp=timestamp,
        source=source_name,
        description=description,
        severity=severity,
        artifact_path=file_path
    )
    events.append(event)

    return events

# Function to parse XML log file (simplified)
def parse_xml_log(file_path, source_name):
    events = []

    try:
        import xml.etree.ElementTree as ET
        tree = ET.parse(file_path)
        root = tree.getroot()

        # Find all elements that might be log entries
        log_entries = []
        for entry_tag in ["entry", "event", "record", "log", "item"]:
            entries = root.findall(f".//{entry_tag}")
            if entries:
                log_entries.extend(entries)

        # If no specific tags found, use all child elements
        if not log_entries and len(list(root)) > 0:
            log_entries = list(root)

        for entry in log_entries:
            # Find timestamp
            timestamp = None
            for time_tag in ["time", "timestamp", "date", "created", "occurred"]:
                time_elem = entry.find(f".//{time_tag}")
                if time_elem is not None and time_elem.text:
                    try:
                        timestamp = parse_timestamp(time_elem.text)
                        break
                    except ValueError:
                        # @defprog-exempt: try next time element; ValueError from strptime is expected
                        continue

            if timestamp is None:
                # Check attributes for timestamp
                for attr_name, attr_value in entry.attrib.items():
                    if any(keyword in attr_name.lower() for keyword in ["time", "date", "timestamp"]):
                        try:
                            timestamp = parse_timestamp(attr_value)
                            break
                        except ValueError:
                            # @defprog-exempt: try next attribute; ValueError from strptime is expected
                            continue

            if timestamp is None:
                # If no timestamp found, use file modification time
                file_time = os.path.getmtime(file_path)
                timestamp = datetime.datetime.fromtimestamp(file_time)

            # Find message/description
            description = None
            for msg_tag in ["message", "description", "msg", "text", "content"]:
                msg_elem = entry.find(f".//{msg_tag}")
                if msg_elem is not None and msg_elem.text:
                    description = msg_elem.text
                    break

            if description is None:
                # If no description found, use the entry's text or XML representation
                if entry.text and entry.text.strip():
                    description = entry.text.strip()
                else:
                    description = ET.tostring(entry, encoding="unicode")

            # Find severity
            severity = "info"
            for sev_tag in ["severity", "level", "priority", "type"]:
                sev_elem = entry.find(f".//{sev_tag}")
                if sev_elem is not None and sev_elem.text:
                    severity_val = sev_elem.text.lower()
                    if any(keyword in severity_val for keyword in ["error", "critical", "fail"]):
                        severity = "error"
                    elif any(keyword in severity_val for keyword in ["warn", "alert"]):
                        severity = "warning"
                    break

            event = TimelineEvent(
                timestamp=timestamp,
                source=source_name,
                description=description,
                severity=severity,
                artifact_path=file_path
            )
            events.append(event)
    except Exception as e:
        logger.error(f"Error parsing XML log {file_path}: {e}")

    return events

# Function to generate HTML report
def generate_html_report(timeline, case_info, output_file):
    logger.info(f"Generating HTML report: {output_file}")

    html_template = """<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Incident Timeline: {case_name}</title>
    <style>
        body {{ font-family: Arial, sans-serif; margin: 0; padding: 20px; color: #333; }}
        .container {{ max-width: 1200px; margin: 0 auto; }}
        header {{ margin-bottom: 30px; }}
        h1 {{ color: #e67e22; margin: 0; }}
        .case-info {{ background: #f9f9f9; padding: 15px; border-left: 5px solid #e67e22; margin: 20px 0; }}
        .case-info h2 {{ margin-top: 0; }}
        .timeline {{ position: relative; }}
        .timeline::before {{ content: ''; position: absolute; top: 0; bottom: 0; left: 20px; width: 4px; background: #ddd; }}
        .event {{ position: relative; margin-bottom: 20px; padding-left: 50px; }}
        .event::before {{ content: ''; position: absolute; top: 0; left: 16px; width: 12px; height: 12px; border-radius: 50%; background: #999; }}
        .event.error::before {{ background: #e74c3c; }}
        .event.warning::before {{ background: #f39c12; }}
        .event.info::before {{ background: #3498db; }}
        .event-time {{ font-weight: bold; color: #666; }}
        .event-source {{ font-style: italic; color: #888; }}
        .event-desc {{ margin-top: 5px; }}
        .error {{ border-left: 3px solid #e74c3c; padding-left: 10px; }}
        .warning {{ border-left: 3px solid #f39c12; padding-left: 10px; }}
        .info {{ border-left: 3px solid #3498db; padding-left: 10px; }}
        footer {{ margin-top: 30px; text-align: center; font-size: 0.8em; color: #888; }}
    </style>
</head>
<body>
    <div class="container">
        <header>
            <h1>Incident Timeline: {case_name}</h1>
            <p>Generated by Orion-X Phoenix Edition v1.5.5 on {generation_date}</p>
        </header>

        <div class="case-info">
            <h2>Case Information</h2>
            <p><strong>Case ID:</strong> {case_id}</p>
            <p><strong>Analyst:</strong> {analyst}</p>
            <p><strong>Date Range:</strong> {date_range}</p>
            <p><strong>Total Events:</strong> {event_count}</p>
        </div>

        <div class="timeline">
            {timeline_events}
        </div>

        <footer>
            <p>Generated using Orion-X Phoenix Edition v1.5.5 Storyboard Generator</p>
        </footer>
    </div>
</body>
</html>"""

    # Sort timeline events
    timeline.sort_events()

    # Determine date range
    if timeline.events:
        start_date = timeline.events[0].timestamp
        end_date = timeline.events[-1].timestamp
        date_range = f"{start_date.strftime('%Y-%m-%d %H:%M:%S')} to {end_date.strftime('%Y-%m-%d %H:%M:%S')}"
    else:
        date_range = "N/A"

    # Build timeline HTML
    timeline_html = ""
    for event in timeline.events:
        timeline_html += f"""
        <div class="event {event.severity}">
            <div class="event-time">{event.timestamp.strftime('%Y-%m-%d %H:%M:%S')}</div>
            <div class="event-source">{event.source}</div>
            <div class="event-desc">{event.description}</div>
        </div>
        """

    # Fill in template
    html_content = html_template.format(
        case_name=case_info.get("case_name", "Incident Investigation"),
        generation_date=datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S"),
        case_id=case_info.get("case_id", "N/A"),
        analyst=case_info.get("analyst", "N/A"),
        date_range=date_range,
        event_count=len(timeline.events),
        timeline_events=timeline_html
    )

    # Write HTML file
    try:
        with open(output_file, "w") as f:
            f.write(html_content)
        logger.info(f"HTML report successfully written to {output_file}")
        return True
    except Exception as e:
        logger.error(f"Error writing HTML report: {e}")
        return False

# Function to generate text report
def generate_text_report(timeline, case_info, output_file):
    logger.info(f"Generating text report: {output_file}")

    # Sort timeline events
    timeline.sort_events()

    # Determine date range
    if timeline.events:
        start_date = timeline.events[0].timestamp
        end_date = timeline.events[-1].timestamp
        date_range = f"{start_date.strftime('%Y-%m-%d %H:%M:%S')} to {end_date.strftime('%Y-%m-%d %H:%M:%S')}"
    else:
        date_range = "N/A"

    try:
        with open(output_file, "w") as f:
            # Write header
            f.write("===============================================\n")
            f.write(f"INCIDENT TIMELINE: {case_info.get('case_name', 'Incident Investigation')}\n")
            f.write("===============================================\n")
            f.write(f"Generated by Orion-X Phoenix Edition v1.5.5 on {datetime.datetime.now().strftime('%Y-%m-%d %H:%M:%S')}\n\n")

            # Write case info
            f.write("CASE INFORMATION\n")
            f.write("-----------------\n")
            f.write(f"Case ID: {case_info.get('case_id', 'N/A')}\n")
            f.write(f"Analyst: {case_info.get('analyst', 'N/A')}\n")
            f.write(f"Date Range: {date_range}\n")
            f.write(f"Total Events: {len(timeline.events)}\n\n")

            # Write timeline
            f.write("TIMELINE OF EVENTS\n")
            f.write("-----------------\n")

            for event in timeline.events:
                f.write(f"[{event.timestamp.strftime('%Y-%m-%d %H:%M:%S')}] ")
                f.write(f"[{event.severity.upper()}] ")
                f.write(f"[{event.source}] ")
                f.write(f"{event.description}\n")

            f.write("\n")
            f.write("===============================================\n")
            f.write("Generated using Orion-X Phoenix Edition v1.5.5 Storyboard Generator\n")

        logger.info(f"Text report successfully written to {output_file}")
        return True
    except Exception as e:
        logger.error(f"Error writing text report: {e}")
        return False

def main():
    parser = argparse.ArgumentParser(description="Orion-X Storyboard Generator")
    parser.add_argument("-i", "--input", help="Input directory or file(s)", required=True, nargs="+")
    parser.add_argument("-o", "--output", help="Output file for the report", required=True)
    parser.add_argument("-f", "--format", help="Output format (html or text)", choices=["html", "text"], default="html")
    parser.add_argument("-c", "--case-name", help="Case name", default="Incident Investigation")
    parser.add_argument("-id", "--case-id", help="Case ID", default=f"ORIONX-{datetime.datetime.now().strftime('%Y%m%d')}")
    parser.add_argument("-a", "--analyst", help="Analyst name", default=os.environ.get("USER", "Unknown"))
    args = parser.parse_args()

    # Initialize timeline
    timeline = Timeline()

    # Process input files
    input_files = []
    for input_path in args.input:
        if os.path.isdir(input_path):
            # Recursively find all files in directory
            for root, _, files in os.walk(input_path):
                for file in files:
                    input_files.append(os.path.join(root, file))
        elif os.path.isfile(input_path):
            input_files.append(input_path)
        else:
            logger.warning(f"Input path not found: {input_path}")

    # Process each file
    for file_path in input_files:
        source_name = os.path.basename(file_path)
        events = parse_log_file(file_path, source_name)

        for event in events:
            timeline.add_event(event)

    # Sort timeline
    timeline.sort_events()

    if not timeline.events:
        logger.error("No events found in input files.")
        return 1

    # Prepare case info
    case_info = {
        "case_name": args.case_name,
        "case_id": args.case_id,
        "analyst": args.analyst
    }

    # Generate report
    success = False
    if args.format == "html":
        success = generate_html_report(timeline, case_info, args.output)
    else:
        success = generate_text_report(timeline, case_info, args.output)

    if success:
        print(f"Report generated successfully: {args.output}")
        return 0
    else:
        print("Failed to generate report.")
        return 1

if __name__ == "__main__":
    sys.exit(main())
