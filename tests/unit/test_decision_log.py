"""Parser tests for scripts/decisions/decision_log.py (DEC-PHASE13-045, #97).

Fixture text, not the tree: both comment styles, continuation lines, blank
comment lines as paragraph breaks, dividers as block ends, duplicate ids,
@canonical resolution, pipe escaping, references and malformed blocks. The
tree itself is checked by tests/unit/test_decision_log.sh.
"""

import importlib.util
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("decision_log", ROOT / "scripts/decisions/decision_log.py")
dl = importlib.util.module_from_spec(SPEC)
sys.modules["decision_log"] = dl
SPEC.loader.exec_module(dl)

HASH = """\
#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# @decision DEC-PHASE13-037
# @title The QEMU gate runs on a pinned runner image (ubuntu-24.04), not
#   ubuntu-latest
# @status accepted
# @rationale On 2026-11-02 GitHub moved ubuntu-latest from 24.04 to 26.04
#   between two runs of this workflow.
#
#   A second paragraph, after a blank comment line, is still the rationale.
# ---------------------------------------------------------------------------
set -u
"""

SLASH = """\
// @decision DEC-PHASE12-043
// @title Pipes | in titles | are escaped
// @status accepted
// @date 2026-10-01
// @category OSINT
// @rationale a | b
//   c | d
var x = 1;
"""


def parse(text, path="f"):
    return dl.parse_text(text, path)


def test_hash_block_with_continuation_and_paragraphs():
    (b,) = parse(HASH, "x.sh")
    assert b.id == "DEC-PHASE13-037" and b.line == 3 and b.token == "#"
    assert b.is_full and not b.is_reference
    assert b.tags["title"] == "The QEMU gate runs on a pinned runner image (ubuntu-24.04), not ubuntu-latest"
    assert b.tags["rationale"].startswith("On 2026-11-02 GitHub moved ubuntu-latest from 24.04 to 26.04 between two runs")
    assert "\n" in b.tags["rationale"]            # paragraph break kept in the value
    assert "A second paragraph" in b.tags["rationale"]
    assert "-----" not in b.tags["rationale"]     # the divider ended the block
    assert b.end == 11                            # end includes the terminating divider line


def test_slash_block_tags_and_pipe_escaping():
    (b,) = parse(SLASH, "x.js")
    assert b.token == "//" and b.is_full
    assert b.tags["date"] == "2026-10-01" and b.tags["category"] == "OSINT"
    assert dl.one_line(b.tags["title"]) == "Pipes \\| in titles \\| are escaped"
    assert dl.one_line(b.tags["rationale"]) == "a \\| b c \\| d"


def test_c_comment_html_comment_and_plain_docstring_blocks():
    css = "/*\n * @decision DEC-PHASE11-010\n * @title T\n * @status accepted\n * @rationale R\n *   more */\nbody{}\n"
    (b,) = parse(css, "x.css")
    assert b.is_full and b.tags["rationale"] == "R more"
    svg = '<svg>\n  <!-- @decision DEC-PHASE13-018\n       @title T\n       @status accepted\n       @rationale R -->\n  <circle/>\n</svg>\n'
    (b,) = parse(svg, "x.svg")
    assert b.is_full and b.tags["rationale"] == "R" and b.end == 5
    one_liner = '<svg>\n  <!-- @decision DEC-PHASE12-127 — distinct glyph -->\n</svg>\n'
    (b,) = parse(one_liner, "y.svg")
    assert b.is_reference and b.end == 2
    doc = '"""Module.\n\n@decision DEC-PHASE12-063\n@title T\n@status accepted\n@rationale R\n  continued\n\nNot part of it.\n"""\n'
    (b,) = parse(doc, "x.py")
    assert b.is_full and b.tags["rationale"] == "R continued"


def test_reference_partial_and_duplicate_detection():
    text = (
        "# @decision DEC-PHASE12-001\n# @title A\n# @status accepted\n# @rationale a\n"
        "x = 1\n"
        "# @decision DEC-PHASE12-001\n# @title B\n# @status accepted\n# @rationale b\n"
        "y = 2\n"
        "# @decision DEC-PHASE12-002\n# @title only a title\n"
        "z = 3\n"
        "# @decision DEC-PHASE12-003\n"
        "w = 4  # DEC-PHASE12-004 is mentioned but never defined\n"
    )
    blocks = parse(text, "scripts/x.py")
    kinds = [(b.id, b.is_full, b.is_reference) for b in blocks]
    assert kinds == [("DEC-PHASE12-001", True, False), ("DEC-PHASE12-001", True, False),
                     ("DEC-PHASE12-002", False, False), ("DEC-PHASE12-003", False, True)]
    assert blocks[2].missing == ["status", "rationale"]
    mentions = {"DEC-PHASE12-004": ["scripts/x.py:14"]}
    scan = dl.Scan(root=Path("/nonexistent"), blocks=blocks, mentions=mentions, files_scanned=1)
    problems = dl.check(scan, None, 12)
    joined = "\n".join(problems)
    assert "scripts/x.py:1: DEC-PHASE12-001 has 2 full blocks and 0 marked @canonical" in joined
    assert "scripts/x.py:6" in joined
    assert "scripts/x.py:11: DEC-PHASE12-002 block is missing @status, @rationale" in joined
    assert "DEC-PHASE12-002 has no full block" in joined
    assert "scripts/x.py:14: DEC-PHASE12-003 has no full block" in joined and "references only at scripts/x.py:14" in joined
    assert "DEC-PHASE12-004 is referenced (1 place(s)) but has no @decision block" in joined
    assert len(problems) == 5


def test_canonical_resolves_duplicates_and_rows_are_sorted():
    text = (
        "# @decision DEC-PHASE12-010\n# @title Site two\n# @status accepted\n# @date 2026-09-14\n# @rationale two\n"
        "a = 1\n"
        "# @decision DEC-PHASE12-010\n# @canonical\n# @title Site one\n# @status accepted\n# @date 2026-09-14\n# @rationale one\n"
        "b = 2\n"
        "# @decision DEC-PHASE12-002\n# @title Earlier id\n# @status superseded by DEC-PHASE12-010\n# @date 2026-09-13\n# @rationale e\n"
        "c = 3\n"
        "# @decision DEC-PHASE11-001\n# @title Not selected\n# @status accepted\n# @date 2026-08-01\n# @rationale n\n"
    )
    blocks = parse(text, "scripts/awareness/x.py")
    scan = dl.Scan(root=Path("/nonexistent"), blocks=blocks, mentions={}, files_scanned=1)
    assert dl.check(scan, None, 12) == []
    assert dl.table(scan, None, 12) == (
        "| ID | Date | Decision | Rationale |\n"
        "|----|------|----------|-----------|\n"
        "| DEC-PHASE12-002 | 2026-09-13 | [DETECTION] Earlier id (status: superseded by DEC-PHASE12-010) | e |\n"
        "| DEC-PHASE12-010 | 2026-09-14 | [DETECTION] Site one | one |\n"
    )
    assert dl.table(scan, {11}, None).count("| DEC-") == 1


def test_category_mapping_and_override():
    def blk(path, **tags):
        return dl.Block(id="DEC-PHASE12-999", path=path, line=1, token="#", tags=tags)
    assert dl.block_category(blk("scripts/awareness/orionx-postured")) == "DETECTION"
    assert dl.block_category(blk(".github/workflows/release.yml")) == "RELEASE"
    assert dl.block_category(blk(".github/workflows/qemu-test.yml")) == "CI"
    assert dl.block_category(blk("iso/config/hooks/live/0700-x.hook.chroot")) == "BUILD"
    assert dl.block_category(blk("iso/config/package-lists/orionx.list.chroot")) == "PACKAGES"
    assert dl.block_category(blk("docs/x.md")) == "DOCS"
    assert dl.block_category(blk("unknown/place.txt")) == "MISC"
    assert dl.block_category(blk("unknown/place.txt", category="[Custom]")) == "CUSTOM"


def test_region_bounds_and_write(tmp_path):
    plan = tmp_path / "MASTER_PLAN.md"
    plan.write_text("## Decision Log\n\n" + dl.REGION_START_LINE + "\nold\n" + dl.REGION_END_LINE + "\n\n## Risk Register\n")
    assert dl.read_region(plan.read_text()) == "old\n"
    assert dl.write_region(tmp_path, "new\n") is True
    assert dl.read_region(plan.read_text()) == "new\n"
    assert dl.write_region(tmp_path, "new\n") is False
    assert "## Risk Register" in plan.read_text()


def test_hand_written_ids_exclude_generated_region(tmp_path):
    plan = tmp_path / "MASTER_PLAN.md"
    plan.write_text(
        "## Decision Log\n\n| ID | Date | Decision | Rationale |\n|--|--|--|--|\n| DEC-PHASE13-000 | d | x | y |\n\n"
        + dl.REGION_START_LINE + "\n| DEC-PHASE12-001 | d | x | y |\n" + dl.REGION_END_LINE + "\n\n"
        "| DEC-PHASE7-001 | d | x | y |\n\n## Risk Register\n\n| DEC-PHASE13-099 | not in the section |\n")
    assert dl.hand_written_ids(tmp_path) == {"DEC-PHASE13-000", "DEC-PHASE7-001"}


def test_phase_selection():
    assert dl.parse_phase("PHASE12") == 12 and dl.parse_phase("dec-phase7") == 7
    assert dl.selected("DEC-PHASE12-001", None, 12) and dl.selected("DEC-PHASE13-001", None, 12)
    assert not dl.selected("DEC-PHASE11-019", None, 12)
    assert not dl.selected("DEC-MESH-001", None, 1)          # non-phase families are never generated
    assert dl.selected("DEC-PHASE9-001", {9}, None) and not dl.selected("DEC-PHASE9-001", {10}, None)
    assert dl.sort_key("DEC-PHASE12-101") > dl.sort_key("DEC-PHASE12-099") > dl.sort_key("DEC-PHASE9-021")
