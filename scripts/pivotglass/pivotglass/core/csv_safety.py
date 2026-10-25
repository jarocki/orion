"""Spreadsheet-safe value handling for CSV exports."""

from __future__ import annotations

from typing import Any


_FORMULA_PREFIXES = ("=", "+", "-", "@")


def spreadsheet_safe_cell(value: Any) -> Any:
    """Return *value* with spreadsheet formula interpretation disabled.

    CSV quoting only protects the file structure; spreadsheet applications may
    still evaluate a string whose first non-whitespace character is a formula
    prefix. Prefixing such strings with an apostrophe preserves the displayed
    value while forcing spreadsheet applications to treat the cell as text.
    Non-string values are returned unchanged.
    """

    if isinstance(value, str) and value.lstrip().startswith(_FORMULA_PREFIXES):
        return f"'{value}"
    return value
