#!/usr/bin/env python3
"""Register Swift files with the hand-written iOS Xcode project.

The project lists every source explicitly — it does not use file-system
synchronised groups — so a new file is invisible to the build until it appears in
three places: a PBXFileReference, a PBXBuildFile, and the children of the main
group plus the files of the Sources phase. This does exactly that, and is a no-op
for files already registered.

    python3 Scripts/register-ios-source.py iOS/MobileCrop.swift iOS/CropView.swift
"""
import re
import sys
from pathlib import Path

PROJECT = Path(__file__).resolve().parent.parent/"iOS/AnaLine.xcodeproj/project.pbxproj"
GROUP_MARKER = "5F3C81A7D9244E60B8C4A1D2"   # last source file referenced in the group
PRODUCT_MARKER = "38A007151ABE87CC01A5B6E9"  # the built product, listed last


def ident(index: int, kind: int) -> str:
    return "D1C0FFEE%04d0000000000%04d" % (kind, index)


def next_index(text: str) -> int:
    """Continue past every identifier this script has already handed out."""
    used = [int(m) for m in re.findall(r"D1C0FFEE0001000000000000(\d\d)", text)]
    return max(used, default=-1) + 1


def main(paths: list[str]) -> int:
    text = PROJECT.read_text()
    added = 0
    next_free = next_index(text)
    for offset, path in enumerate(sorted(set(paths))):
        index = next_free + offset
        relative = "../" + path if not path.startswith("../") else path
        if f'path = "{relative}"' in text:
            print("already registered:", path)
            continue
        file_ref, build_file = ident(index, 1), ident(index, 2)
        reference = (f'{file_ref} = {{ isa = PBXFileReference; lastKnownFileType = sourcecode.swift; '
                     f'path = "{relative}"; sourceTree = SOURCE_ROOT; }};')
        build = f'{build_file} = {{ isa = PBXBuildFile; fileRef = {file_ref}; }};'
        # 1. the two new objects, after the first line of the objects dictionary
        anchor = text.index("\n", text.index("objects = {")) + 1
        text = text[:anchor] + reference + "\n" + build + "\n" + text[anchor:]
        # 2. the group's children, 3. the Sources phase's files
        assert GROUP_MARKER in text and PRODUCT_MARKER in text, "group markers moved"
        text = text.replace(GROUP_MARKER + ",", GROUP_MARKER + f",{file_ref},", 1)
        sources = re.search(r"isa = PBXSourcesBuildPhase;.*?files = \(([^)]*)\)", text, re.S)
        assert sources, "no Sources phase"
        text = text[:sources.end(1)] + ("," + build_file) + text[sources.end(1):]
        added += 1
        print("registered:", path)
    if added:
        PROJECT.write_text(text)
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
