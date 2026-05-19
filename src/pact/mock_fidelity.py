"""Mock fidelity scanner — detects drift between test mocks and real module exports.

Mechanical scanner (no LLM). Parses vi.mock/jest.mock factory return values
in TypeScript/JavaScript test files and compares them to what the real module
actually exports. Identifies two kinds of drift:

  ghost_export  — mock exports a name the real module doesn't (consumer code
                  may rely on a non-existent property at runtime → silent bug)
  missing_mock  — real module exports a name the mock doesn't (API surface
                  hidden from tests, but not necessarily a runtime bug)

Ghost exports are always a defect: the consumer's fallback path runs at runtime
and tests never catch it because the mock supplies the missing property.

Run:  pact check-mocks <project-dir>
Fix:  pact check-mocks <project-dir> --fix
"""

from __future__ import annotations

import logging
import re
from dataclasses import dataclass, field
from pathlib import Path

logger = logging.getLogger(__name__)

SKIP_DIRS = frozenset({
    "node_modules", ".git", "__pycache__", ".pact", "dist", "build",
    ".venv", "coverage", ".next", ".nuxt",
})

# ── Regexes ────────────────────────────────────────────────────────

# vi.mock('path', ...) or jest.mock('path', ...)
_MOCK_CALL_RE = re.compile(
    r'(?:vi|jest)\.mock\(\s*(?P<q>["\'])(?P<path>.+?)(?P=q)',
)

# Named top-level keys in an object literal: foo: or 'foo': or "foo":
# Must be at the start of a line (after optional whitespace + comma/brace)
_OBJECT_KEY_RE = re.compile(
    r"""(?:^|[{,])\s*(?:'([^']+)'|"([^"]+)"|([a-zA-Z_$][a-zA-Z0-9_$]*))\s*:(?!:)""",
    re.MULTILINE,
)

# export function name / export const name / export class name / export enum name
_EXPORT_DECL_RE = re.compile(
    r"""(?m)^[ \t]*export\s+
        (?:declare\s+)?
        (?:
            (?:abstract\s+)?class\s+([A-Za-z_$][A-Za-z0-9_$]*)
          | (?:async\s+)?function\s*\*?\s*([A-Za-z_$][A-Za-z0-9_$]*)
          | const\s+([A-Za-z_$][A-Za-z0-9_$]*)
          | let\s+([A-Za-z_$][A-Za-z0-9_$]*)
          | var\s+([A-Za-z_$][A-Za-z0-9_$]*)
          | enum\s+([A-Za-z_$][A-Za-z0-9_$]*)
        )
    """,
    re.VERBOSE,
)

# export { name, name as alias, ... }  (not export type { ... })
_EXPORT_BRACE_RE = re.compile(
    r"""(?m)^[ \t]*export\s+(?!type\s*\{)(?:\w+\s+)?
        \{([^}]+)\}
    """,
    re.VERBOSE,
)

# export default (anything)
_EXPORT_DEFAULT_RE = re.compile(r"(?m)^[ \t]*export\s+default\b")

# individual name inside braces: name or name as alias
_BRACE_MEMBER_RE = re.compile(
    r"\b([A-Za-z_$][A-Za-z0-9_$]*)\s*(?:as\s+([A-Za-z_$][A-Za-z0-9_$]*))?"
)


# ── Data structures ────────────────────────────────────────────────


@dataclass
class MockDefinition:
    """One vi.mock/jest.mock call found in a test file."""
    test_file: Path
    mock_path: str
    mock_exports: set[str]


@dataclass
class MockFidelityFinding:
    """Discrepancy between what a mock exports and what the real module exports."""
    test_file: Path
    mock_path: str
    resolved_source: Path | None
    ghost_exports: set[str]    # In mock, NOT in real → runtime undefined
    missing_exports: set[str]  # In real, NOT in mock → hidden from tests
    mock_exports: set[str]
    real_exports: set[str]

    @property
    def has_ghost(self) -> bool:
        return bool(self.ghost_exports)


@dataclass
class MockFidelityReport:
    """Full mock fidelity scan result."""
    findings: list[MockFidelityFinding] = field(default_factory=list)
    scanned_test_files: int = 0
    scanned_mocks: int = 0

    @property
    def ghost_findings(self) -> list[MockFidelityFinding]:
        return [f for f in self.findings if f.has_ghost]


# ── Parsing helpers ────────────────────────────────────────────────


def _extract_factory_segment(source: str, after_path_end: int) -> str:
    """Return ~3000 chars of source after the mock module-path argument.

    This covers the factory function body without trying to full-parse JS.
    """
    return source[after_path_end: after_path_end + 3000]


def _extract_mock_keys(factory_segment: str) -> set[str]:
    """Extract top-level property keys from the first object literal in factory_segment.

    Handles:
      () => ({ key: value })
      async () => { return { key: value }; }
      () => { const x = ...; return { key: value }; }
    """
    # Find the first `{` that looks like a return-object opening
    # (not a function body — a function body would be followed by statements,
    # an object literal is followed by key:value pairs)
    open_brace = -1
    for m in re.finditer(r"\{", factory_segment):
        pos = m.start()
        # Skip if preceded by `=>` (arrow fn body) — we want the *return* object
        before = factory_segment[:pos].rstrip()
        if before.endswith("=>") or before.endswith("return"):
            open_brace = pos
            break
    if open_brace == -1:
        # Fallback: just use the first `{`
        idx = factory_segment.find("{")
        if idx == -1:
            return set()
        open_brace = idx

    # Extract text inside the outer braces (depth 1)
    keys: set[str] = set()
    depth = 0
    i = open_brace
    in_str = False
    str_ch = ""
    buf: list[str] = []

    while i < len(factory_segment):
        ch = factory_segment[i]
        if in_str:
            if ch == "\\" and i + 1 < len(factory_segment):
                i += 2
                continue
            if ch == str_ch:
                in_str = False
        elif ch in ('"', "'", "`"):
            in_str = True
            str_ch = ch
        elif ch == "{":
            depth += 1
            if depth == 1:
                i += 1
                continue
        elif ch == "}":
            depth -= 1
            if depth == 0:
                break
        if depth == 1:
            buf.append(ch)
        i += 1

    inner = "".join(buf)
    for m in _OBJECT_KEY_RE.finditer("{" + inner + "}"):
        key = m.group(1) or m.group(2) or m.group(3)
        if key:
            keys.add(key)
    return keys


def _scan_test_file(test_file: Path) -> list[MockDefinition]:
    """Parse one test file and return all mock definitions."""
    try:
        src = test_file.read_text(encoding="utf-8", errors="replace")
    except OSError:
        return []

    results: list[MockDefinition] = []
    for m in _MOCK_CALL_RE.finditer(src):
        mock_path = m.group("path")
        segment = _extract_factory_segment(src, m.end())
        keys = _extract_mock_keys(segment)
        if keys:
            results.append(MockDefinition(
                test_file=test_file,
                mock_path=mock_path,
                mock_exports=keys,
            ))
    return results


def _extract_real_exports(source_file: Path) -> set[str]:
    """Extract all runtime-visible export names from a TS/JS module."""
    try:
        src = source_file.read_text(encoding="utf-8", errors="replace")
    except OSError:
        return set()

    exports: set[str] = set()

    # export function/const/class/let/var/enum name
    for m in _EXPORT_DECL_RE.finditer(src):
        name = next((g for g in m.groups() if g), None)
        if name:
            exports.add(name)

    # export { name, name as alias }
    for m in _EXPORT_BRACE_RE.finditer(src):
        for nm in _BRACE_MEMBER_RE.finditer(m.group(1)):
            alias = nm.group(2)
            original = nm.group(1)
            exports.add(alias if alias else original)

    # export default
    if _EXPORT_DEFAULT_RE.search(src):
        exports.add("default")

    # Remove TypeScript type keyword false positives
    exports.discard("type")
    exports.discard("interface")

    return exports


_TS_EXTENSIONS = [".ts", ".tsx", ".js", ".jsx", "/index.ts", "/index.tsx", "/index.js"]


def _resolve_module_path(test_file: Path, mock_path: str, project_root: Path) -> Path | None:
    """Resolve a vi.mock module path to an actual file.

    Handles:
    - Relative paths: ../../src/page_components
    - Bare aliases:  page_components  (→ src/page_components)
    - Vite resolve.alias style bare names
    """
    if mock_path.startswith("."):
        base = (test_file.parent / mock_path).resolve()
    else:
        # Bare module name — try src/<name> first, then project root/<name>
        base = (project_root / "src" / mock_path).resolve()

    for ext in _TS_EXTENSIONS:
        if ext.startswith("/"):
            candidate = base / ext.lstrip("/")
        else:
            stem = base.stem
            candidate = base.parent / (stem + ext)
        if candidate.exists() and candidate.is_file():
            return candidate

    # Also try the base path itself (if it already has an extension)
    if base.exists() and base.is_file():
        return base

    return None


# ── Public API ─────────────────────────────────────────────────────


def scan_project(project_root: Path) -> MockFidelityReport:
    """Scan a TypeScript/JavaScript project for mock-implementation drift.

    Walks all *.test.ts / *.spec.ts files (recursively), finds vi.mock/jest.mock
    calls, extracts factory return keys, then compares to real module exports.
    """
    root = project_root.resolve()
    report = MockFidelityReport()

    test_files: list[Path] = []
    for pattern in (
        "**/*.test.ts", "**/*.test.tsx",
        "**/*.spec.ts", "**/*.spec.tsx",
        "**/*.test.js", "**/*.spec.js",
    ):
        for f in root.glob(pattern):
            if not any(part in SKIP_DIRS for part in f.parts):
                test_files.append(f)

    report.scanned_test_files = len(test_files)

    for test_file in sorted(test_files):
        mocks = _scan_test_file(test_file)
        report.scanned_mocks += len(mocks)

        for mock_def in mocks:
            resolved = _resolve_module_path(test_file, mock_def.mock_path, root)
            if resolved is None:
                logger.debug("Could not resolve mock path %r from %s", mock_def.mock_path, test_file)
                continue

            real_exports = _extract_real_exports(resolved)
            if not real_exports:
                logger.debug("No exports found in %s", resolved)
                continue

            ghost = mock_def.mock_exports - real_exports
            missing = real_exports - mock_def.mock_exports

            if ghost or missing:
                report.findings.append(MockFidelityFinding(
                    test_file=test_file,
                    mock_path=mock_def.mock_path,
                    resolved_source=resolved,
                    ghost_exports=ghost,
                    missing_exports=missing,
                    mock_exports=mock_def.mock_exports,
                    real_exports=real_exports,
                ))

    return report


def render_report(report: MockFidelityReport, project_root: Path | None = None) -> str:
    """Render scan results as human-readable text."""
    root = project_root or Path.cwd()
    lines: list[str] = []

    lines.append(
        f"Mock Fidelity Scan — {report.scanned_test_files} test files, "
        f"{report.scanned_mocks} mocks analysed"
    )

    ghost_findings = report.ghost_findings
    if not ghost_findings:
        lines.append("✓ No ghost exports — all mocks align with real module APIs.")
        if report.findings:
            lines.append(
                f"  ({len(report.findings)} mocks have missing coverage "
                f"but no ghost exports.)"
            )
        return "\n".join(lines)

    lines.append(
        f"\n{len(ghost_findings)} mock(s) with ghost exports "
        f"(runtime will receive undefined instead of the expected value):\n"
    )

    for f in ghost_findings:
        try:
            tf = f.test_file.relative_to(root)
        except ValueError:
            tf = f.test_file
        sf: object = f.resolved_source
        if sf is not None:
            try:
                sf = f.resolved_source.relative_to(root)  # type: ignore[union-attr]
            except ValueError:
                pass

        lines.append(f"  {tf}")
        lines.append(f"    mocked module: {f.mock_path!r}  →  real file: {sf}")
        lines.append(f"    GHOST (mock has, real doesn't): {sorted(f.ghost_exports)}")
        if f.missing_exports:
            lines.append(
                f"    missing  (real has, mock doesn't): {sorted(f.missing_exports)}"
            )
        lines.append("")

    lines.append(
        "Tip: run  pact check-mocks <dir> --fix  to let the AI fixer patch consumer code."
    )
    return "\n".join(lines)


def find_consumer_files(
    ghost_export: str,
    resolved_source: Path,
    project_root: Path,
) -> list[Path]:
    """Find source files that import the real module and reference the ghost export.

    These are the files whose runtime behaviour is broken — they rely on a
    property that only exists in the test mock, not in the real module.
    """
    import subprocess

    root = project_root.resolve()
    candidates: list[Path] = []

    # Quick grep for files that import the resolved source's parent dir name
    module_name = resolved_source.parent.name
    try:
        result = subprocess.run(
            ["grep", "-rl", module_name, str(root / "src")],
            capture_output=True, text=True, timeout=10,
        )
        for line in result.stdout.splitlines():
            p = Path(line.strip())
            if p.exists() and p != resolved_source:
                candidates.append(p)
    except (subprocess.TimeoutExpired, FileNotFoundError):
        pass

    # Further filter: files that actually reference the ghost export name
    consumers: list[Path] = []
    for p in candidates:
        try:
            content = p.read_text(encoding="utf-8", errors="replace")
            if ghost_export in content:
                consumers.append(p)
        except OSError:
            pass

    return consumers
