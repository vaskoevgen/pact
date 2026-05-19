"""Mock fidelity fixer agent — AI-powered fix for mock-implementation drift.

Given a MockFidelityFinding, this agent:
1. Reads the consumer files that reference the ghost export
2. Reads the real module's source to understand the actual API
3. Uses an LLM to propose a minimal fix to the consumer (not the mock)
   so that the consumer uses the real API instead of the ghost export

The fix is returned as a FixProposal with old_code / new_code / explanation.
The caller decides whether to apply it.
"""

from __future__ import annotations

import logging
from dataclasses import dataclass
from pathlib import Path

from pydantic import BaseModel, Field

from pact.agents.base import AgentBase
from pact.mock_fidelity import MockFidelityFinding, find_consumer_files

logger = logging.getLogger(__name__)

# ── Schemas ────────────────────────────────────────────────────────


class FixProposal(BaseModel):
    """A proposed patch to a consumer file."""
    file_path: str = Field(description="Absolute path to the file to patch")
    old_code: str = Field(description="Exact string to replace (verbatim, including indentation)")
    new_code: str = Field(description="Replacement string")
    explanation: str = Field(description="One sentence: why this fixes the runtime bug")
    confidence: str = Field(
        description="high | medium | low — how confident the agent is in this fix",
        default="medium",
    )


class FixProposalList(BaseModel):
    """List of fix proposals for one finding."""
    proposals: list[FixProposal] = Field(
        description="Ordered list of patches to apply (apply in order). Empty if no fix needed.",
        default_factory=list,
    )
    summary: str = Field(
        description="1-2 sentence summary of what was wrong and how the fix addresses it",
    )


# ── System prompt ──────────────────────────────────────────────────

_SYSTEM = """You are starting fresh on this fix with no prior context.

You are a precise code surgeon. A test mock exports a property that the real
module does not export (a 'ghost export'). Consumer code checks for this ghost
property at runtime and always falls into a silent fallback path, rendering
nothing. Your job is to patch the consumer so it uses the REAL module API.

Rules:
- Fix the consumer, not the mock. The mock is a test artifact and should
  accurately reflect what tests expected — update it separately if needed.
- Propose the MINIMAL diff. Do not refactor, rename, or add logging.
- old_code must be a verbatim substring of the consumer file (whitespace exact).
- Prefer using exported functions the real module already provides (e.g.
  buildPageComponentMap) over inventing new abstractions.
- If multiple consumer files need patching, include one FixProposal per file.
- If the real module already provides an equivalent to the ghost export under a
  different name, use that name.
- confidence=high when the patch is unambiguous; medium when the real API usage
  requires inference; low when you cannot reliably determine the fix.
"""

# ── Agent function ─────────────────────────────────────────────────

_MAX_FILE_CHARS = 8000  # keep context manageable


def _read_truncated(path: Path, max_chars: int = _MAX_FILE_CHARS) -> str:
    try:
        text = path.read_text(encoding="utf-8", errors="replace")
    except OSError:
        return "(unreadable)"
    if len(text) > max_chars:
        return text[:max_chars] + f"\n... (truncated at {max_chars} chars)"
    return text


async def propose_fix(
    agent: AgentBase,
    finding: MockFidelityFinding,
    project_root: Path,
) -> FixProposalList:
    """Use the LLM to propose fixes for a mock-implementation drift finding.

    Args:
        agent: Configured AgentBase instance (budget + backend).
        finding: The ghost-export finding to fix.
        project_root: Root of the TypeScript project being analysed.

    Returns:
        FixProposalList with zero or more patches to apply.
    """
    if not finding.ghost_exports:
        return FixProposalList(proposals=[], summary="No ghost exports — nothing to fix.")

    real_src = finding.resolved_source
    real_content = _read_truncated(real_src) if real_src else "(source not found)"

    # Find consumer files that reference the ghost exports
    consumers: list[Path] = []
    for ghost in finding.ghost_exports:
        consumers.extend(find_consumer_files(ghost, real_src or project_root, project_root))
    consumers = list(dict.fromkeys(consumers))  # deduplicate, preserve order

    consumer_sections: list[str] = []
    for cp in consumers[:4]:  # cap at 4 consumers
        try:
            rel = cp.relative_to(project_root)
        except ValueError:
            rel = cp
        consumer_sections.append(
            f"=== Consumer: {rel} ===\n{_read_truncated(cp)}"
        )

    if not consumer_sections:
        return FixProposalList(
            proposals=[],
            summary=(
                f"Ghost exports {sorted(finding.ghost_exports)} found in mock of "
                f"{finding.mock_path!r} but no consumer files reference them by name. "
                f"The mock may simply be over-specified."
            ),
        )

    prompt = f"""A vi.mock call in the test suite exports names that the real module does NOT export.
At runtime, the consumer falls back to a no-op (renders nothing / returns undefined).

## Ghost exports (in mock, NOT in real module)
{sorted(finding.ghost_exports)}

## Real module exports (what the module ACTUALLY provides)
{sorted(finding.real_exports)}

## Real module source ({finding.resolved_source})
```typescript
{real_content}
```

## Consumer files that reference the ghost export(s)
{chr(10).join(consumer_sections)}

---

Propose the minimal patch(es) to the consumer file(s) so they use the real
module API instead of the ghost export. Return a FixProposalList.
"""

    result, in_tok, out_tok = await agent.assess(
        FixProposalList,
        prompt=prompt,
        system=_SYSTEM,
        max_tokens=4096,
    )

    logger.info(
        "mock_fixer: %d proposals for ghost=%s (%d+%d tokens)",
        len(result.proposals),
        sorted(finding.ghost_exports),
        in_tok,
        out_tok,
    )
    return result


def apply_proposal(proposal: FixProposal) -> bool:
    """Apply a single fix proposal to the file on disk.

    Returns True if the patch was applied, False if old_code was not found.
    """
    path = Path(proposal.file_path)
    try:
        content = path.read_text(encoding="utf-8")
    except OSError as e:
        logger.error("Cannot read %s: %s", path, e)
        return False

    if proposal.old_code not in content:
        logger.warning(
            "old_code not found verbatim in %s — skipping patch", path
        )
        return False

    new_content = content.replace(proposal.old_code, proposal.new_code, 1)
    path.write_text(new_content, encoding="utf-8")
    logger.info("Patched %s", path)
    return True
