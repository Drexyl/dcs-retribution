"""Lua-level checks for the plugin scripts shipped with generated missions.

DCS runs mission scripts on Lua 5.1, so the scripts are loaded with lupa's Lua
5.1 runtime: every plugin script must at least compile, none may depend on MIST
any more, and the standalone Lua unit tests (mocked DCS/MOOSE environment) must
pass.
"""

from __future__ import annotations

import re
from pathlib import Path
from typing import Any

import pytest

lua51 = pytest.importorskip("lupa.lua51")

REPO_ROOT = Path(__file__).resolve().parents[2]
PLUGINS_DIR = REPO_ROOT / "resources" / "plugins"
LUA_TESTS_DIR = Path(__file__).resolve().parent

# Kept in the repository for reference only; no longer loaded by any mission.
LEGACY_MIST = "mist_4_5_126.lua"

# The Pretense init script is assembled from these fragments by
# PretenseLuaGenerator (with generated Lua in between), so they only compile
# once concatenated.
PRETENSE_INIT_FRAGMENTS = (
    "init_header.lua",
    "init_body_1.lua",
    "init_body_2.lua",
    "init_body_3.lua",
    "init_footer.lua",
)

MIST_REFERENCE = re.compile(r"\bmist\s*\.\s*\w+|\bmist\s*\[")


def _plugin_scripts() -> list[Path]:
    return sorted(
        path
        for path in PLUGINS_DIR.rglob("*.lua")
        if path.name != LEGACY_MIST and path.name not in PRETENSE_INIT_FRAGMENTS
    )


def _read(path: Path) -> str:
    return path.read_text(encoding="utf-8-sig", errors="replace")


def _compile(source: str, chunk_name: str) -> Any:
    """Compiles Lua source without running it; returns the error message or None."""
    lua = lua51.LuaRuntime(unpack_returned_tuples=True)
    compile_chunk = lua.eval(
        "function(source, name) local chunk, err = loadstring(source, name) "
        "return err end"
    )
    return compile_chunk(source, f"@{chunk_name}")


@pytest.mark.parametrize(
    "script", _plugin_scripts(), ids=lambda p: p.relative_to(PLUGINS_DIR).as_posix()
)
def test_plugin_script_compiles_as_lua_5_1(script: Path) -> None:
    assert _compile(_read(script), script.name) is None


def test_pretense_init_fragments_compile_when_assembled() -> None:
    source = "\n".join(
        _read(PLUGINS_DIR / "pretense" / fragment)
        for fragment in PRETENSE_INIT_FRAGMENTS
    )
    assert _compile(source, "pretense_init") is None


@pytest.mark.parametrize(
    "script",
    [p for p in PLUGINS_DIR.rglob("*.lua") if p.name not in (LEGACY_MIST, "Moose.lua")],
    ids=lambda p: p.relative_to(PLUGINS_DIR).as_posix(),
)
def test_plugin_script_does_not_use_mist(script: Path) -> None:
    code_lines = [
        line
        for line in _read(script).splitlines()
        if not line.lstrip().startswith("--")
    ]
    offenders = [line.strip() for line in code_lines if MIST_REFERENCE.search(line)]
    assert not offenders, f"{script.name} still calls MIST: {offenders[:5]}"


@pytest.mark.parametrize(
    "lua_test", ["land_relocate_test.lua", "retribution_utils_test.lua"]
)
def test_lua_unit_tests_pass(lua_test: str, monkeypatch: pytest.MonkeyPatch) -> None:
    # The Lua tests load the scripts under test relative to the repository root.
    monkeypatch.chdir(REPO_ROOT)
    lua = lua51.LuaRuntime(unpack_returned_tuples=True)
    # lupa raises LuaError if any check() fails.
    lua.execute(_read(LUA_TESTS_DIR / lua_test))
