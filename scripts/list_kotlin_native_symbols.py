#!/usr/bin/env python3
"""Print the expected JNI symbol name for every `external fun` in a Kotlin
source tree.

Used by CI to reconcile the Kotlin side of the Android binding against the
`Java_*` exports in the shipped .so files. A Kotlin `external fun` whose JNI
counterpart is missing throws UnsatisfiedLinkError at runtime; a JNI export
with no Kotlin caller is dead code that the version script does not scope
away.

Usage:
    scripts/list_kotlin_native_symbols.py <kotlin-source-root>

The `external fun` is expected to live inside an `object` or `class`; the
containing type name is used to build the fully-qualified class name that
the JNI mangling wants.

Reference: https://docs.oracle.com/en/java/javase/17/docs/specs/jni/design.html
(short-form mangling for non-overloaded methods).
"""

from __future__ import annotations

import os
import re
import sys


PACKAGE_RE = re.compile(r"^\s*package\s+([\w.]+)")
CONTAINER_RE = re.compile(
    r"^\s*(?:internal\s+|private\s+|public\s+|open\s+|abstract\s+|sealed\s+)*"
    r"(?:object|class|interface)\s+([A-Za-z_]\w*)"
)
EXTERNAL_RE = re.compile(r"\bexternal\s+fun\s+([A-Za-z_]\w*)\s*\(")


def mangle(name: str) -> str:
    """Apply JNI short-form mangling to a package/class/method name."""
    out = []
    for ch in name:
        if ch == ".":
            out.append("_")
        elif ch == "_":
            out.append("_1")
        elif ch == ";":
            out.append("_2")
        elif ch == "[":
            out.append("_3")
        elif ch.isascii() and (ch.isalnum() or ch == "_"):
            out.append(ch)
        else:
            out.append("_0" + f"{ord(ch):04x}")
    return "".join(out)


def collect(root: str) -> set[str]:
    symbols: set[str] = set()
    for dirpath, _, files in os.walk(root):
        for name in files:
            if not name.endswith(".kt"):
                continue
            path = os.path.join(dirpath, name)
            symbols.update(_process(path))
    return symbols


def _process(path: str) -> set[str]:
    """Walk one .kt file, tracking package + open containers, and emit the
    expected JNI symbol name for every `external fun` declaration."""
    pkg = ""
    depth = 0
    containers: list[tuple[str, int]] = []
    found: set[str] = set()

    with open(path, encoding="utf-8") as fh:
        for line in fh:
            m = PACKAGE_RE.match(line)
            if m:
                pkg = m.group(1)

            m = CONTAINER_RE.match(line)
            if m and "{" in line:
                containers.append((m.group(1), depth))

            for m in EXTERNAL_RE.finditer(line):
                method = m.group(1)
                cls = containers[-1][0] if containers else ""
                sym = "Java_" + mangle(pkg) + "_" + mangle(cls) + "_" + mangle(method)
                found.add(sym)

            depth += line.count("{") - line.count("}")
            while containers and containers[-1][1] >= depth:
                containers.pop()

    return found


def main() -> int:
    if len(sys.argv) != 2:
        print(__doc__.strip(), file=sys.stderr)
        return 2
    root = sys.argv[1]
    if not os.path.isdir(root):
        print(f"error: {root} is not a directory", file=sys.stderr)
        return 2
    for sym in sorted(collect(root)):
        print(sym)
    return 0


if __name__ == "__main__":
    sys.exit(main())
