#!/usr/bin/env python3
"""check_settings_writers — every operator settings file has exactly one writer (#95).

Driven by tests/unit/test_settings_writers.sh; usable alone:

    python3 tests/unit/lib/check_settings_writers.py [ROOT] [--json]

DEC-PHASE13-048 (scripts/control_center/settings_drawer.py): one writer per
settings file. This proves it statically, from the code that ships, without
importing any of it:

* Python (every *.py and python-shebang file under scripts/, tools/ and
  iso/config/includes.chroot): path constants are resolved through module
  assignments, `from M import NAME`, `alias.CONST` across modules, parameter
  defaults, local assignments and function return values. A write is
  open(T, w|a|x|+), T.open(w...), os.open(T, O_WRONLY|O_RDWR|O_CREAT),
  T.write_text/write_bytes/touch, os.replace/os.rename/shutil.move|copy*(_, T),
  T2.replace(T)/T2.rename(T), or a call that hands T to a function which
  writes that parameter (settings_io.atomic_write_text and the like, found
  the same way, to a fixed point). The writer is the module where T is first
  resolved to a settings file: a helper that writes whatever path it is given
  is a tool, its caller is the writer.
* A derived path is a different file: T.with_suffix/with_name/parent, string
  concatenation and f-strings stop resolution, so a temp or lock file beside
  a setting is not a second writer, while its os.replace onto the setting is
  the write.
* Shell (*.sh, *.chroot hooks and sh/bash-shebang files under scripts/,
  tools/, iso/config): >, >>, tee, cp, install, mv and ln whose target names
  the file, directly or through a variable assigned a path that does.
* A copy shipped under iso/config/includes.chroot/etc/skel is a writer too.

It fails when a registered file has more than one writer or a writer other
than the declared one, and when the code names a ~/.config/orionx file that
is not registered here (a new setting must declare its writer).

/var/lib/orionx holds state (the healing chain, capture rings, GeoIP data,
the bus key, first-boot flag), each written by the daemon that owns it, not
operator settings; it is out of scope by design and stated as such.
"""
from __future__ import annotations

import ast
import json
import re
import sys
from pathlib import Path

# name under ~/.config/orionx -> (declared writer module, or None for
#                                 hand-edited by the operator; what it is)
REGISTRY: dict[str, tuple[str | None, str]] = {
    "autonomy.json": ("scripts/healing/healing_lib.py",
                      "auto-healing consent; `orionx-heal autonomy` (Workbench → Engine)"),
    "threat-posture": ("scripts/control_center/helpers/posture_data.py",
                       "requested posture tier; Cockpit → Settings (request_tier)"),
    "rain.json": ("scripts/rain/rain_lib.py",
                  "R.A.I.N. settings; Cockpit → Settings and `orionx-rain` (save_config)"),
    "music.json": ("scripts/music/orionx_synth.py", "DJ deck state; orionx-dj / orionx-music"),
    "tuning.json": ("scripts/awareness/orionx-tune", "squelch/tune rules; `orionx-tune` via tuning_lib.write_rules"),
    "healing.json": (None, "engine tuning (never-block list, TTLs); edited by hand"),
    "logquery/credentials.env": (None, "logquery source credentials; edited by hand"),
    "logquery/priv.pem": (None, "logquery SSH key; supplied by the operator"),
}
# The Nebula warm-up "trigger" is systemd's enablement link, written by the
# operator's `systemctl enable`; no shipped code may enable it (DEC-PHASE10-010).
WARMUP_UNIT = "nebula-warmup.service"

SCAN_DIRS = ("scripts", "tools", "iso/config/includes.chroot", "iso/config/hooks")
SKIP_PARTS = ("cyberchef", "godseye/app", "node_modules", "__pycache__", ".git")

STOP_ATTRS = {"with_suffix", "with_name", "with_stem", "parent", "parents", "name", "stem", "suffix"}
PASS_ATTRS = {"expanduser", "resolve", "absolute"}
PASS_FUNCS = {"Path", "PurePath", "PosixPath", "str", "fspath", "expanduser", "join", "joinpath", "abspath",
              "realpath", "normpath"}


def _skip(p: Path) -> bool:
    s = str(p)
    return any(part in s for part in SKIP_PARTS)


def _kind(p: Path) -> str | None:
    if p.suffix == ".py":
        return "py"
    if p.suffix in (".sh", ".chroot", ".binary"):
        return "sh"
    try:
        with p.open("rb") as fh:
            head = fh.readline(200)
    except OSError:
        return None
    if head.startswith(b"#!"):
        if b"python" in head:
            return "py"
        if re.search(rb"\b(ba|da|z)?sh\b", head):
            return "sh"
    return None


def name_match(value: str) -> str | None:
    """The registry name a string constant identifies as a path, or None."""
    for name in REGISTRY:
        if value == name or value.endswith("/" + name):
            return name
    return None


# ---------------------------------------------------------------- python model
class Module:
    def __init__(self, rel: str, tree: ast.Module) -> None:
        self.rel = rel
        self.tree = tree
        self.stem = Path(rel).name.removesuffix(".py").replace("-", "_")
        self.consts: dict[str, set[str]] = {}          # module-level name -> settings names
        self.aliases: dict[str, str] = {}              # local alias -> module stem
        self.from_imports: dict[str, tuple[str, str]] = {}   # local name -> (stem, name)
        self.funcs: dict[str, ast.FunctionDef] = {}
        self.returns: dict[str, set[str]] = {}         # function -> settings names it returns
        self.param_sinks: dict[str, set[int | str]] = {}   # function -> param indexes/names it writes
        for node in ast.walk(tree):
            if isinstance(node, ast.Import):
                for a in node.names:
                    self.aliases[a.asname or a.name.split(".")[0]] = a.name.split(".")[-1]
            elif isinstance(node, ast.ImportFrom):
                for a in node.names:
                    local = a.asname or a.name
                    # `from ..helpers import posture_data as P` imports a module;
                    # `from rain_lib import CONFIG_FILE` imports a name. Both kept.
                    self.aliases.setdefault(local, a.name)
                    self.from_imports[local] = ((node.module or "").split(".")[-1], a.name)
        for node in tree.body:
            if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)):
                self.funcs[node.name] = node
            elif isinstance(node, ast.ClassDef):
                for sub in node.body:
                    if isinstance(sub, (ast.FunctionDef, ast.AsyncFunctionDef)):
                        self.funcs.setdefault(sub.name, sub)


class Model:
    def __init__(self, modules: list[Module]) -> None:
        self.mods = modules
        self.by_stem: dict[str, list[Module]] = {}
        for m in modules:
            self.by_stem.setdefault(m.stem, []).append(m)

    # -- resolution ---------------------------------------------------------
    def _stem_consts(self, stem: str, name: str) -> set[str]:
        out: set[str] = set()
        for m in self.by_stem.get(stem, []):
            out |= m.consts.get(name, set())
        return out

    def _stem_returns(self, stem: str, name: str) -> set[str]:
        out: set[str] = set()
        for m in self.by_stem.get(stem, []):
            out |= m.returns.get(name, set())
        return out

    def ident(self, mod: Module, node: ast.AST, local: dict[str, set[str]]) -> set[str]:
        """Settings names `node` evaluates to as a path (identity only)."""
        if isinstance(node, ast.Constant) and isinstance(node.value, str):
            n = name_match(node.value)
            return {n} if n else set()
        if isinstance(node, ast.Name):
            if node.id in local:
                return set(local[node.id])
            if node.id in mod.consts:
                return set(mod.consts[node.id])
            if node.id in mod.from_imports:
                stem, nm = mod.from_imports[node.id]
                return self._stem_consts(stem, nm)
            return set()
        if isinstance(node, ast.Attribute):
            if node.attr in STOP_ATTRS:
                return set()
            if isinstance(node.value, ast.Name) and node.value.id in mod.aliases:
                return self._stem_consts(mod.aliases[node.value.id], node.attr)
            return set()
        if isinstance(node, ast.BinOp) and isinstance(node.op, ast.Div):
            right = self.ident(mod, node.right, local)
            if right:
                return right
            # `X / "orionx" / "rain.json"` is caught by the right operand; a
            # constant prefix with an unknown tail is not a settings path.
            return set()
        if isinstance(node, (ast.IfExp,)):
            return self.ident(mod, node.body, local) | self.ident(mod, node.orelse, local)
        if isinstance(node, ast.BoolOp):
            out: set[str] = set()
            for v in node.values:
                out |= self.ident(mod, v, local)
            return out
        if isinstance(node, ast.Call):
            f = node.func
            fname = f.id if isinstance(f, ast.Name) else f.attr if isinstance(f, ast.Attribute) else ""
            if isinstance(f, ast.Attribute) and f.attr in PASS_ATTRS:
                return self.ident(mod, f.value, local)
            if fname in PASS_FUNCS:
                out = set()
                for a in node.args:
                    out |= self.ident(mod, a, local)
                return out
            if isinstance(f, ast.Name):
                if f.id in mod.returns:
                    return set(mod.returns[f.id])
                if f.id in mod.from_imports:
                    stem, nm = mod.from_imports[f.id]
                    return self._stem_returns(stem, nm)
            if isinstance(f, ast.Attribute) and isinstance(f.value, ast.Name) and f.value.id in mod.aliases:
                return self._stem_returns(mod.aliases[f.value.id], f.attr)
        return set()

    def scope_locals(self, mod: Module, fn: ast.AST) -> dict[str, set[str]]:
        """Flow-insensitive: a name is a settings path if any assignment (or default) makes it one."""
        local: dict[str, set[str]] = {}
        if isinstance(fn, (ast.FunctionDef, ast.AsyncFunctionDef)):
            args = fn.args.posonlyargs + fn.args.args
            for a, d in zip(args[len(args) - len(fn.args.defaults):], fn.args.defaults):
                got = self.ident(mod, d, local)
                if got:
                    local.setdefault(a.arg, set()).update(got)
            for a, d in zip(fn.args.kwonlyargs, fn.args.kw_defaults):
                if d is not None:
                    got = self.ident(mod, d, local)
                    if got:
                        local.setdefault(a.arg, set()).update(got)
        for _ in range(3):
            for node in ast.walk(fn):
                targets, value = [], None
                if isinstance(node, ast.Assign):
                    targets, value = node.targets, node.value
                elif isinstance(node, (ast.AnnAssign, ast.AugAssign)) and node.value is not None:
                    targets, value = [node.target], node.value
                elif isinstance(node, ast.NamedExpr):
                    targets, value = [node.target], node.value
                elif isinstance(node, (ast.With, ast.AsyncWith)):
                    for item in node.items:
                        if isinstance(item.optional_vars, ast.Name):
                            got = self.ident(mod, item.context_expr, local)
                            if got:
                                local.setdefault(item.optional_vars.id, set()).update(got)
                    continue
                if value is None:
                    continue
                got = self.ident(mod, value, local)
                if not got:
                    continue
                for t in targets:
                    if isinstance(t, ast.Name):
                        local.setdefault(t.id, set()).update(got)
        return local

    # -- fixed point over constants, returns and parameter sinks -------------
    def solve(self) -> None:
        for _ in range(8):
            changed = False
            for m in self.mods:
                for node in m.tree.body:
                    tgt, val = [], None
                    if isinstance(node, ast.Assign):
                        tgt, val = node.targets, node.value
                    elif isinstance(node, ast.AnnAssign) and node.value is not None:
                        tgt, val = [node.target], node.value
                    if val is None:
                        continue
                    got = self.ident(m, val, {})
                    for t in tgt:
                        if isinstance(t, ast.Name) and got - m.consts.get(t.id, set()):
                            m.consts.setdefault(t.id, set()).update(got)
                            changed = True
                for fname, fn in m.funcs.items():
                    local = self.scope_locals(m, fn)
                    rets: set[str] = set()
                    for node in ast.walk(fn):
                        if isinstance(node, ast.Return) and node.value is not None:
                            rets |= self.ident(m, node.value, local)
                    if rets - m.returns.get(fname, set()):
                        m.returns.setdefault(fname, set()).update(rets)
                        changed = True
                    sinks = self._param_sinks(m, fn)
                    if sinks - m.param_sinks.get(fname, set()):
                        m.param_sinks.setdefault(fname, set()).update(sinks)
                        changed = True
            if not changed:
                return

    def _params(self, fn: ast.FunctionDef) -> list[str]:
        return [a.arg for a in fn.args.posonlyargs + fn.args.args]

    def _param_sinks(self, mod: Module, fn: ast.FunctionDef) -> set[int | str]:
        """Parameters this function writes (as a path), by index and name."""
        params = self._params(fn)
        derived: dict[str, str] = {p: p for p in params}
        for _ in range(3):
            for node in ast.walk(fn):
                if isinstance(node, ast.Assign) and len(node.targets) == 1 and isinstance(node.targets[0], ast.Name):
                    src = self._param_of(node.value, derived)
                    if src:
                        derived[node.targets[0].id] = src
        out: set[int | str] = set()
        for target in self._sink_targets(mod, fn):
            src = self._param_of(target, derived)
            if src:
                idx = params.index(src)
                out |= {idx, src}
        return out

    def _param_of(self, node: ast.AST, derived: dict[str, str]) -> str | None:
        if isinstance(node, ast.Name):
            return derived.get(node.id)
        if isinstance(node, ast.Call):
            f = node.func
            fname = f.id if isinstance(f, ast.Name) else f.attr if isinstance(f, ast.Attribute) else ""
            if isinstance(f, ast.Attribute) and f.attr in PASS_ATTRS:
                return self._param_of(f.value, derived)
            if fname in PASS_FUNCS and node.args:
                return self._param_of(node.args[0], derived)
        if isinstance(node, ast.IfExp):
            return self._param_of(node.body, derived) or self._param_of(node.orelse, derived)
        return None

    def _callee_sinks(self, mod: Module, call: ast.Call) -> set[int | str]:
        f = call.func
        if isinstance(f, ast.Name):
            if f.id in mod.param_sinks:
                return mod.param_sinks[f.id]
            if f.id in mod.from_imports:
                stem, nm = mod.from_imports[f.id]
                out: set[int | str] = set()
                for m in self.by_stem.get(stem, []):
                    out |= m.param_sinks.get(nm, set())
                return out
        if isinstance(f, ast.Attribute):
            if isinstance(f.value, ast.Name) and f.value.id in mod.aliases:
                out = set()
                for m in self.by_stem.get(mod.aliases[f.value.id], []):
                    out |= m.param_sinks.get(f.attr, set())
                return out
            if isinstance(f.value, ast.Name) and f.value.id == "self" and f.attr in mod.param_sinks:
                return mod.param_sinks[f.attr]
        return set()

    def _sink_targets(self, mod: Module, scope: ast.AST) -> list[ast.AST]:
        out: list[ast.AST] = []
        for node in ast.walk(scope):
            if not isinstance(node, ast.Call):
                continue
            f = node.func
            if isinstance(f, ast.Name) and f.id == "open" and node.args:
                mode = _mode_arg(node, 1)
                if mode and any(c in mode for c in "wax+"):
                    out.append(node.args[0])
            elif isinstance(f, ast.Attribute):
                base_mod = f.value.id if isinstance(f.value, ast.Name) else ""
                if f.attr == "open" and base_mod == "os" and node.args:
                    flags = ast.unparse(node.args[1]) if len(node.args) > 1 else ""
                    if re.search(r"O_(WRONLY|RDWR|CREAT|TRUNC|APPEND)", flags):
                        out.append(node.args[0])
                elif f.attr == "open" and base_mod not in ("os", "io", "gzip", "bz2", "lzma", "tarfile", "zipfile"):
                    mode = _mode_arg(node, 0)
                    if mode and any(c in mode for c in "wax+"):
                        out.append(f.value)
                elif f.attr in ("write_text", "write_bytes", "touch"):
                    out.append(f.value)
                elif base_mod in ("os", "shutil") and f.attr in ("replace", "rename", "move", "copy", "copy2",
                                                                    "copyfile", "copyfileobj", "symlink", "link"):
                    if len(node.args) >= 2:
                        out.append(node.args[1])
                elif f.attr in ("replace", "rename") and len(node.args) == 1 and not node.keywords:
                    out.append(node.args[0])        # Path.replace(target); str.replace takes two
            sinks = self._callee_sinks(mod, node)
            if sinks:
                for i, a in enumerate(node.args):
                    if i in sinks:
                        out.append(a)
                for kw in node.keywords:
                    if kw.arg in sinks:
                        out.append(kw.value)
        return out

    # -- the answer ------------------------------------------------------------
    def writers(self) -> dict[str, list[tuple[str, int, str]]]:
        found: dict[str, list[tuple[str, int, str]]] = {}
        for m in self.mods:
            scopes: list[ast.AST] = list(m.funcs.values())
            # module level statements that are not function bodies
            top = ast.Module(body=[n for n in m.tree.body
                                   if not isinstance(n, (ast.FunctionDef, ast.AsyncFunctionDef, ast.ClassDef))],
                             type_ignores=[])
            scopes.append(top)
            for cls in [n for n in m.tree.body if isinstance(n, ast.ClassDef)]:
                for sub in cls.body:
                    if isinstance(sub, (ast.FunctionDef, ast.AsyncFunctionDef)) and sub not in scopes:
                        scopes.append(sub)
            for scope in scopes:
                local = self.scope_locals(m, scope)
                for target in self._sink_targets(m, scope):
                    for name in self.ident(m, target, local):
                        found.setdefault(name, []).append((m.rel, getattr(target, "lineno", 0), ast.unparse(target)))
        return found


def _mode_arg(call: ast.Call, pos: int) -> str | None:
    for kw in call.keywords:
        if kw.arg == "mode" and isinstance(kw.value, ast.Constant):
            return str(kw.value.value)
    if len(call.args) > pos and isinstance(call.args[pos], ast.Constant) and isinstance(call.args[pos].value, str):
        return call.args[pos].value
    return None


# ---------------------------------------------------------------- shell + seeds
_SH_WRITE = re.compile(r"(?:>>?|\btee\b(?:\s+-a)?|\b(?:cp|install|mv|ln)\b[^|;&]*?)\s*['\"]?(\S+)")


def shell_writers(rel: str, text: str) -> list[tuple[str, str, int, str]]:
    out = []
    vars_: dict[str, str] = {}
    for i, raw in enumerate(text.splitlines(), 1):
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        m = re.match(r"(?:export\s+|local\s+|readonly\s+)?([A-Za-z_][A-Za-z0-9_]*)=(['\"]?)(.+?)\2\s*$", line)
        if m:
            n = name_match(re.sub(r"[\"'}]", "", m.group(3)).rstrip("/"))
            if n:
                vars_[m.group(1)] = n
        for w in re.finditer(r"(?:\d?>>?|\btee\b(?:\s+-a)?)\s*['\"]?([^\s'\";|&)]+)", line):
            tgt = w.group(1)
            n = name_match(tgt)
            if not n:
                vm = re.fullmatch(r"\$\{?([A-Za-z_][A-Za-z0-9_]*)\}?", tgt)
                n = vars_.get(vm.group(1)) if vm else None
            if n and not tgt.startswith("&"):
                out.append((n, rel, i, line[:120]))
        cm = re.match(r"(?:sudo\s+)?(cp|install|mv|ln)\b(.*)$", line)
        if cm:
            toks = [t.strip("'\"") for t in cm.group(2).split() if not t.startswith("-")]
            if toks:
                tgt = toks[-1]
                n = name_match(tgt)
                if not n:
                    vm = re.fullmatch(r"\$\{?([A-Za-z_][A-Za-z0-9_]*)\}?", tgt)
                    n = vars_.get(vm.group(1)) if vm else None
                if n:
                    out.append((n, rel, i, line[:120]))
    return out


def warmup_enables(rel: str, text: str, kind: str) -> list[str]:
    """Live code that would enable nebula-warmup.service (comments and prose do not count).

    Shell: `systemctl ... enable ... <unit>`, an ln into *.wants/<unit>, or the
    unit inside an array whose name says it is enabled (AUTOSTART_UNITS, ...).
    Python: a list/tuple of string constants holding "enable" and the unit.
    """
    out: list[str] = []
    if kind == "sh":
        array, lines = None, text.splitlines()
        for i, raw in enumerate(lines, 1):
            s = raw.strip()
            if s.startswith("#"):
                continue
            m = re.match(r"(?:local\s+|declare\s+-a\s+)?([A-Za-z_][A-Za-z0-9_]*)=\(", s)
            if m:
                array = m.group(1)
            if array and re.search(r"AUTOSTART|ENABLE", array) and WARMUP_UNIT in s.split("#")[0]:
                out.append(f"{rel}:{i}: {array}: {s[:80]}")
            if array and ")" in s.split("#")[0]:
                array = None
            live = s.split("#")[0]
            if WARMUP_UNIT in live and (re.search(r"\bsystemctl\b.*\benable\b", live)
                                        or re.search(r"\bln\b.*\.wants/", live)):
                out.append(f"{rel}:{i}: {s[:100]}")
    else:
        try:
            tree = ast.parse(text, rel)
        except SyntaxError:
            return out
        for node in ast.walk(tree):
            if isinstance(node, (ast.List, ast.Tuple)):
                vals = [e.value for e in node.elts if isinstance(e, ast.Constant) and isinstance(e.value, str)]
                if "enable" in vals and any(WARMUP_UNIT in v for v in vals):
                    out.append(f"{rel}:{node.lineno}: {ast.unparse(node)[:100]}")
    return out


def discovered_names(text: str) -> set[str]:
    """Every ~/.config/orionx/<file> the code names (string or Path chain)."""
    names = set(m.group(1) for m in re.finditer(r"\.config/orionx/([A-Za-z0-9_.-]+(?:/[A-Za-z0-9_.-]+)?)", text))
    for m in re.finditer(r'"\.config"\s*\)?\s*/\s*"orionx"\s*\)?\s*/\s*"([A-Za-z0-9_.-]+)"', text):
        names.add(m.group(1))
    for m in re.finditer(r'config_dir\(\)\s*/\s*"([A-Za-z0-9_.-]+)"', text):
        names.add(m.group(1))
    return {n.rstrip(".") for n in names if n.strip(".")}


def analyse(root: Path) -> dict:
    py: list[Module] = []
    writers: dict[str, list[tuple[str, int, str]]] = {}
    names: dict[str, set[str]] = {}
    warmup_enablers: list[str] = []
    for d in SCAN_DIRS:
        base = root / d
        if not base.is_dir():
            continue
        for p in sorted(base.rglob("*")):
            if not p.is_file() or _skip(p):
                continue
            kind = _kind(p)
            if kind is None:
                continue
            rel = str(p.relative_to(root))
            try:
                text = p.read_text(encoding="utf-8")
            except (OSError, UnicodeDecodeError):
                continue
            for n in discovered_names(text):
                names.setdefault(n, set()).add(rel)
            if WARMUP_UNIT in text:
                warmup_enablers.extend(warmup_enables(rel, text, kind))
            if kind == "py":
                try:
                    py.append(Module(rel, ast.parse(text, rel)))
                except SyntaxError:
                    continue
            else:
                for n, r, i, line in shell_writers(rel, text):
                    writers.setdefault(n, []).append((r, i, line))
    model = Model(py)
    model.solve()
    for n, sites in model.writers().items():
        writers.setdefault(n, []).extend(sites)
    skel = root / "iso/config/includes.chroot/etc/skel/.config/orionx"
    for n in REGISTRY:
        if (skel / n).exists():
            writers.setdefault(n, []).append((str((skel / n).relative_to(root)), 0, "shipped seed copy"))
    return {"writers": writers, "names": names, "warmup_enablers": warmup_enablers}


def verdict(result: dict) -> tuple[bool, list[str]]:
    ok = True
    lines: list[str] = []
    for name, (declared, what) in REGISTRY.items():
        sites = result["writers"].get(name, [])
        mods = sorted({s[0] for s in sites})
        want = [declared] if declared else []
        good = mods == want
        ok &= good
        tag = "PASS" if good else "FAIL"
        who = ", ".join(mods) or "no code writer"
        lines.append(f"  {tag}: ~/.config/orionx/{name}: {who}  ({what})")
        if not good:
            lines.append(f"        expected {' / '.join(want) or 'no code writer'}; write sites:")
            lines.extend(f"          {r}:{i}: {t}" for r, i, t in sites)
    unregistered = sorted(set(result["names"]) - set(REGISTRY)
                          - {n.split("/")[0] for n in REGISTRY if "/" in n})
    if unregistered:
        ok = False
        for n in unregistered:
            lines.append(f"  FAIL: ~/.config/orionx/{n} is named in {', '.join(sorted(result['names'][n]))} "
                         "but has no declared writer in check_settings_writers.REGISTRY")
    else:
        lines.append(f"  PASS: every ~/.config/orionx file the code names is registered ({len(result['names'])} names)")
    if result["warmup_enablers"]:
        ok = False
        lines.append("  FAIL: shipped code enables nebula-warmup.service (the operator's systemctl is its only writer):")
        lines.extend("          " + s for s in result["warmup_enablers"])
    else:
        lines.append("  PASS: no shipped code enables nebula-warmup.service (the warm-up trigger is the operator's)")
    return ok, lines


def main(argv: list[str]) -> int:
    root = Path(argv[1]).resolve() if len(argv) > 1 and not argv[1].startswith("--") else \
        Path(__file__).resolve().parents[3]
    result = analyse(root)
    if "--json" in argv:
        print(json.dumps({k: (sorted(v) if isinstance(v, (set, list)) else
                              {n: sorted(map(str, s)) for n, s in v.items()}) for k, v in result.items()},
                         indent=1, default=str))
    ok, lines = verdict(result)
    print("\n".join(lines))
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
