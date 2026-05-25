"""Unit tests for representative check_* functions from skill_checks.

Focus: positive + negative path for the small pure-logic checks. Filesystem-
heavy checks (markdown links, attribution leak) are exercised by the shell
smoke tests; here we keep the unit layer tight.
"""

import pytest

from skill_checks import (
    check_description_conformance,
    check_portable_skill_surface,
    check_trigger_overlap,
    pipe_count,
)


# ---- pipe_count -----------------------------------------------------------


def test_pipe_count_plain():
    assert pipe_count("| a | b | c |") == 4


def test_pipe_count_inside_backticks_ignored():
    # The | inside `code` should not count toward column boundaries.
    assert pipe_count("| `a|b` | c |") == 3


def test_pipe_count_escaped_pipe_ignored():
    # \| is the canonical escape; it should not increment the counter.
    assert pipe_count(r"| a \| b | c |") == 3


# ---- check_description_conformance ---------------------------------------


def test_description_happy_path(capsys):
    descs = {
        "think": (
            "Turns rough ideas into approved plans. Use when users ask for planning. "
            "Not for bug fixes or small edits."
        ),
    }
    check_description_conformance(descs)
    out = capsys.readouterr().out
    assert "ok: description think" in out


def test_description_too_short_rejected(capsys):
    with pytest.raises(SystemExit):
        check_description_conformance({"x": "short"})
    assert "DESCRIPTION TOO SHORT" in capsys.readouterr().err


def test_description_too_long_rejected(capsys):
    long_desc = "Word " * 200 + "Not for misuse."
    with pytest.raises(SystemExit):
        check_description_conformance({"x": long_desc})
    assert "DESCRIPTION TOO LONG" in capsys.readouterr().err


def test_description_missing_not_for_clause(capsys):
    with pytest.raises(SystemExit):
        check_description_conformance(
            {"x": "Does many things. Use when users ask for useful things."}
        )
    assert "MISSING EXCLUSION CLAUSE" in capsys.readouterr().err


def test_description_missing_use_when_rejected(capsys):
    with pytest.raises(SystemExit):
        check_description_conformance(
            {"x": "Does many things. Many different things. Not for everything else."}
        )
    assert "MISSING USE-WHEN CUE" in capsys.readouterr().err


def test_description_starting_with_article_rejected(capsys):
    with pytest.raises(SystemExit):
        check_description_conformance(
            {"x": "The skill does things. Not for everything else."}
        )
    assert "STARTS WITH ARTICLE" in capsys.readouterr().err


# ---- check_trigger_overlap ------------------------------------------------


def test_trigger_overlap_disjoint(capsys):
    keywords = {
        "a": {"alpha", "beta"},
        "b": {"gamma", "delta"},
    }
    check_trigger_overlap(keywords)
    out = capsys.readouterr().out
    assert "ok: trigger keyword overlap below threshold" in out


def test_trigger_overlap_high_jaccard_rejected():
    # Jaccard = |{x, y}| / |{x, y, z}| = 2/3 >= 0.5
    keywords = {
        "a": {"x", "y"},
        "b": {"x", "y", "z"},
    }
    with pytest.raises(SystemExit):
        check_trigger_overlap(keywords)


def test_trigger_overlap_empty_safe(capsys):
    check_trigger_overlap({"a": set(), "b": set()})
    out = capsys.readouterr().out
    assert "ok: trigger keyword overlap below threshold" in out


# ---- check_portable_skill_surface -----------------------------------------


def test_portable_skill_surface_happy_path(tmp_path, capsys):
    path = tmp_path / "skills" / "check" / "SKILL.md"
    path.parent.mkdir(parents=True)
    path.write_text("Use project context to choose the platform tool.\n")

    check_portable_skill_surface(tmp_path, [path])
    out = capsys.readouterr().out
    assert "ok: portable skill surface" in out


def test_portable_skill_surface_rejects_downloads_default(tmp_path, capsys):
    path = tmp_path / "skills" / "read" / "SKILL.md"
    path.parent.mkdir(parents=True)
    path.write_text("Save to ~/Downloads/{title}.md by default.\n")

    with pytest.raises(SystemExit):
        check_portable_skill_surface(tmp_path, [path])
    assert "NON-PORTABLE DEFAULT SAVE PATH" in capsys.readouterr().err


def test_portable_skill_surface_rejects_forced_gh(tmp_path, capsys):
    path = tmp_path / "skills" / "check" / "SKILL.md"
    path.parent.mkdir(parents=True)
    path.write_text("Use `gh` CLI for all GitHub interactions, not MCP or raw API.\n")

    with pytest.raises(SystemExit):
        check_portable_skill_surface(tmp_path, [path])
    assert "FORCED GITHUB TOOLING" in capsys.readouterr().err


@pytest.mark.parametrize(
    "private_context",
    [
        "mole-mac",
        "MoleApp",
        "tw93/Mole",
        ".codex/sessions",
        ".codex/memories",
        "rollout_summaries/example.jsonl",
        "thread_id",
        "rollout_path",
        "Dodo",
    ],
)
def test_portable_skill_surface_rejects_private_context(tmp_path, capsys, private_context):
    path = tmp_path / "skills" / "think" / "SKILL.md"
    path.parent.mkdir(parents=True)
    path.write_text(f"Distill the evidence from {private_context}.\n")

    with pytest.raises(SystemExit):
        check_portable_skill_surface(tmp_path, [path])
    assert "PRIVATE PROJECT OR SESSION CONTEXT" in capsys.readouterr().err


def test_portable_skill_surface_warns_on_project_names(tmp_path, capsys):
    path = tmp_path / "skills" / "write" / "SKILL.md"
    path.parent.mkdir(parents=True)
    path.write_text("Use the Mole release flow as the default.\n")

    check_portable_skill_surface(tmp_path, [path])
    out = capsys.readouterr().out
    assert "warn: project-specific names or platform products" in out
    assert "ok: portable skill surface" in out
