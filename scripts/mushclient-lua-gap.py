#!/usr/bin/env python3
"""Audit the Proteles ↔ MUSHclient Lua world-API gap (see docs/MUSHCLIENT_LUA_GAP.md).

Cross-references the canonical MUSHclient world.* function list against (a) the
globals our *generic* plugin shim provides and (b) how often each function is
actually called by real, public Aardwolf plugins vendored in this repo. Prints a
gap ranked by real-world usage, so we implement what plugins need — not all 418.

Static analysis only: the usage count is a call-site grep (a prioritisation
signal, not exact — a local named like a world fn over-counts; a global we
provide through a mechanism the regex misses under-counts). Spot-check the top
entries against the shim before acting on them.

Corpus is in-repo and PUBLIC only (the Aardwolf client package + vendored
plugins) — never the user's own installed plugins. Re-run after the shim or
submodules change:  python3 scripts/mushclient-lua-gap.py
"""
import glob
import os
import re

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# 1. Canonical MUSHclient world.* functions (the reference's own registration).
CANONICAL = f"{ROOT}/submodules/mushclient/scripting/functionlist.cpp"
mush = set()
for line in open(CANONICAL):
    m = re.match(r'\{ "([A-Za-z][A-Za-z0-9_]+)"', line)
    if m:
        mush.add(m.group(1))

# 2. Globals our GENERIC plugin shim exposes (what an arbitrary 3rd-party plugin
#    gets — NOT the S&D-only curated bindings, which are a separate runtime).
SHIM_FILES = [
    "Sources/MudCore/Scripting/LuaRuntime+CompatShim.swift",
    "Sources/MudCore/Scripting/LuaRuntime+CompatShimCore.swift",
    "Sources/MudCore/Scripting/LuaRuntime+CompatHelpers.swift",
    "Sources/MudCore/Scripting/LuaRuntime+CompatShimTimers.swift",
    "Sources/MudCore/Scripting/LuaRuntime+CompatDatabase.swift",
    "Sources/MudCore/Scripting/LuaRuntime+CompatIO.swift",
    "Sources/MudCore/Scripting/LuaRuntime+MiniWindowShim.swift",
]
ours = set()
for rel in SHIM_FILES:
    path = f"{ROOT}/{rel}"
    if not os.path.exists(path):
        continue
    txt = open(path, encoding="utf-8", errors="replace").read()
    ours |= set(re.findall(r'\bfunction\s+([A-Z][A-Za-z0-9_]+)\s*\(', txt))
    ours |= set(re.findall(r'^\s*([A-Z][A-Za-z0-9_]+)\s*=\s*function', txt, re.M))
    ours |= set(re.findall(r'^\s*([A-Z][A-Za-z0-9_]+)\s*=\s*[A-Z][A-Za-z0-9_]+\s*$', txt, re.M))

# 3. Usage corpus — public, in-repo plugins only.
corpus = []
for base in ["submodules/aardwolfclientpackage", "plugins"]:
    for ext in ("*.lua", "*.xml"):
        corpus += glob.glob(f"{ROOT}/{base}/**/{ext}", recursive=True)
corpus = [
    f for f in corpus
    if os.path.basename(f) not in {
        # Reference stubs/documentation, not runnable plugin/helper code. Including
        # this file makes almost every MUSHclient API look "used" once.
        "mushclient_definitions.lua",
    }
]
blobs = {}
for f in corpus:
    try:
        blobs[f] = open(f, encoding="utf-8", errors="replace").read()
    except OSError:
        pass

def call_count(fn, text):
    return len(re.findall(r'(?<![A-Za-z0-9_])' + re.escape(fn) + r'\s*\(', text))

usage = {fn: sum(call_count(fn, text) for text in blobs.values()) for fn in mush}
breadth = {fn: sum(1 for text in blobs.values() if call_count(fn, text) > 0) for fn in mush}
missing_used = sorted(
    ((usage[f], breadth[f], f) for f in mush if f not in ours and usage[f] > 0),
    reverse=True
)
missing_unused = sorted(f for f in mush if f not in ours and usage[f] == 0)

print(f"corpus files: {len(corpus)}")
print(f"MUSHclient world functions: {len(mush)}")
print(f"provided by our generic shim: {len(mush & ours)}")
print(f"missing & used by real plugins: {len(missing_used)}")
print(f"missing & unused (ignorable tail): {len(missing_unused)}")
print("\ncalls files  function")
for count, files, fn in missing_used:
    print(f"{count:5d} {files:5d}  {fn}")
print("\nmissing & unused: " + ", ".join(missing_unused))
