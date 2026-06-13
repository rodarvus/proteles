#!/usr/bin/env python3
"""Regenerate the PackagePluginCatalog id/filename sets from the
aardwolfclientpackage submodule, so the baked snapshot doesn't silently drift as
the package updates.

Extraction is quote-aware (the <plugin> opening tag's attribute values can
contain '>' — which defeats a naive regex — and the files aren't always
well-formed XML, which defeats a strict parser). Prints the two Swift
`Set<String>` literals to paste into
Sources/MudCore/Import/PackagePluginCatalog.swift (review the diff). With
--check, exits non-zero if the catalog is stale.
"""
import sys, re, pathlib

ROOT = pathlib.Path(__file__).resolve().parent.parent
PLUGINS = ROOT / "submodules/aardwolfclientpackage/MUSHclient/worlds/plugins"
CATALOG = ROOT / "Sources/MudCore/Import/PackagePluginCatalog.swift"

def plugin_id(text):
    """The <plugin> element's own id — scanning the opening tag quote-aware so a
    '>' inside an attribute value doesn't end the tag early."""
    start = text.find("<plugin")
    while start != -1:
        index, quote = start + len("<plugin"), None
        while index < len(text):
            char = text[index]
            if quote:
                if char == quote: quote = None
            elif char in "\"'":
                quote = char
            elif char == ">":
                break
            index += 1
        match = re.search(r'\bid\s*=\s*"([0-9a-fA-F]{24})"', text[start:index])
        if match:
            return match.group(1).lower()
        start = text.find("<plugin", index)
    return None

def scan():
    ids, names = set(), set()
    for xml in sorted(PLUGINS.glob("*.xml")):
        names.add(xml.name.lower())
        if pid := plugin_id(xml.read_text(encoding="latin-1")):
            ids.add(pid)
    return ids, names

def current():
    text = CATALOG.read_text()
    return set(re.findall(r'"([0-9a-f]{24})"', text)), set(re.findall(r'"([a-z0-9_]+\.xml)"', text))

ids, names = scan()
if "--check" in sys.argv:
    cids, cnames = current()
    if ids != cids:
        print(f"ids drift: missing={sorted(ids - cids)} stale={sorted(cids - ids)}")
    if names != cnames:
        print(f"filename drift: missing={sorted(names - cnames)} stale={sorted(cnames - names)}")
    ok = ids == cids and names == cnames
    print("catalog matches submodule ✓" if ok else "STALE — regenerate", file=sys.stderr)
    sys.exit(0 if ok else 1)

def emit(name, values):
    print(f"    public static let {name}: Set<String> = [")
    for value in sorted(values):
        print(f'        "{value}",')
    print("    ]\n")
print(f"// {len(ids)} ids / {len(names)} filenames from the aardwolfclientpackage submodule")
emit("ids", ids)
emit("filenames", names)
