#!/usr/bin/env python3
"""Release-snapshot checks: Android configuration, brand, icon resources, secrets.

Run from the repository root:  python tool/check_release_snapshot.py

The script only reads files. It is used by CI and by hand before publishing:
pixel-level icon invariants live in test/branding_1_0_test.dart and run with
`flutter test`; this script covers metadata, packaging contract and credentials.
"""

from __future__ import annotations

import json
import re
import struct
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
BRAND_NAME = "Петербург в деталях"
APPLICATION_ID = "ru.smartnavigator.spb"
OLD_BRAND = "SmartNavigator SPb"

failures: list[str] = []
checked = 0


def check(condition: bool, message: str) -> None:
    global checked
    checked += 1
    if not condition:
        failures.append(message)


def read(relative: str) -> str:
    path = ROOT / relative
    check(path.is_file(), f"missing file: {relative}")
    return path.read_text(encoding="utf-8") if path.is_file() else ""


def png_size(path: Path) -> tuple[int, int] | None:
    data = path.read_bytes()
    if len(data) < 24 or data[:8] != b"\x89PNG\r\n\x1a\n" or data[12:16] != b"IHDR":
        return None
    width, height = struct.unpack(">II", data[16:24])
    return width, height


# --- Android packaging contract -------------------------------------------------

gradle = read("android/app/build.gradle")
manifest = read("android/app/src/main/AndroidManifest.xml")
strings = read("android/app/src/main/res/values/strings.xml")
pubspec = read("pubspec.yaml")

check(f"applicationId '{APPLICATION_ID}'" in gradle, "applicationId changed")
check("minSdk 26" in gradle, "minSdk is not 26")
check("targetSdk 36" in gradle, "targetSdk is not 36")
check(
    "signingConfigs.debug" not in gradle,
    "release build still falls back to the debug signing config",
)
check(
    "validateReleaseSigning" in gradle and "key.properties" in gradle,
    "release signing validation is missing from android/app/build.gradle",
)
check('android:label="@string/app_name"' in manifest, "manifest label is not app_name")
check("android:icon=" in manifest and "android:roundIcon=" in manifest, "icon refs missing")
check(
    'android:usesCleartextTraffic="false"' in manifest,
    "main manifest must keep cleartext traffic disabled",
)
check(BRAND_NAME in strings, f'strings.xml app_name is not "{BRAND_NAME}"')
check("name: smart_navigator_spb" in pubspec, "pubspec package name changed")
check("version: 1.1.1+3" in pubspec, "pubspec version is not 1.1.1+3")

# --- Icon resources ------------------------------------------------------------

DENSITIES = {
    "mdpi": (48, 108),
    "hdpi": (72, 162),
    "xhdpi": (96, 216),
    "xxhdpi": (144, 324),
    "xxxhdpi": (192, 432),
}
for density, (legacy, adaptive) in DENSITIES.items():
    for name, expected in (
        ("ic_launcher", legacy),
        ("ic_launcher_round", legacy),
        ("ic_launcher_background", adaptive),
        ("ic_launcher_foreground", adaptive),
        ("ic_launcher_monochrome", adaptive),
    ):
        path = ROOT / f"android/app/src/main/res/mipmap-{density}/{name}.png"
        check(path.is_file(), f"missing icon: mipmap-{density}/{name}.png")
        if path.is_file():
            size = png_size(path)
            check(
                size == (expected, expected),
                f"mipmap-{density}/{name}.png is {size}, expected {expected}x{expected}",
            )

for name in ("ic_launcher.xml", "ic_launcher_round.xml"):
    adaptive = read(f"android/app/src/main/res/mipmap-anydpi-v26/{name}")
    for layer in ("ic_launcher_background", "ic_launcher_foreground", "ic_launcher_monochrome"):
        check(
            f"@mipmap/{layer}" in adaptive,
            f"mipmap-anydpi-v26/{name} does not reference {layer}",
        )

source_icon = ROOT / "docs/branding/original_app_icon.png"
check(source_icon.is_file(), "approved source icon is missing")
if source_icon.is_file():
    metadata = json.loads(read("docs/branding/icon_metadata.json"))
    import hashlib

    digest = hashlib.sha256(source_icon.read_bytes()).hexdigest()
    check(
        digest == metadata.get("sha256"),
        "approved source icon does not match the recorded SHA-256",
    )

# --- Brand strings in the application -----------------------------------------

strings_dart = read("lib/core/constants/app_strings.dart")
for expected in (
    f"appTitle = '{BRAND_NAME}'",
    "appCreator = 'Создатель: Денис Аниськов'",
    "appTagline =",
    "appSlogan = 'Замечай больше. Открывай Петербург.'",
):
    check(expected in strings_dart, f"missing brand string in app_strings.dart: {expected}")

for path in list((ROOT / "lib").rglob("*.dart")) + [ROOT / "android/app/src/main/AndroidManifest.xml", ROOT / "android/app/src/main/res/values/strings.xml"]:
    text = path.read_text(encoding="utf-8")
    check(
        OLD_BRAND not in text,
        f"old brand name still present in {path.relative_to(ROOT).as_posix()}",
    )

# --- Credentials ---------------------------------------------------------------

FORBIDDEN_NAMES = {
    "key.properties",
    "local.properties",
    "staging.local.json",
}
FORBIDDEN_SUFFIXES = {".jks", ".keystore", ".p12", ".key", ".pid"}
IGNORED_DIRS = {".git", ".dart_tool", "build", ".gradle", ".idea", ".vscode", ".kotlin"}

PLACEHOLDER_MARKERS = (
    "YOUR_",
    "REPLACE_",
    "CHANGE_ME",
    "CHANGEME",
    "PLACEHOLDER",
    "EXAMPLE",
    "SAMPLE",
    "FAKE",
    "SYNTHETIC",
    "DUMMY",
    "TEST",
    "TODO",
)

ASSIGNMENT = re.compile(
    r"(MAPKIT_API_KEY|GEOCODER_API_KEY|SUGGEST_API_KEY|OPENROUTER_API_KEY|"
    r"API_KEY|ACCESS_TOKEN|SECRET|PASSWORD)\s*[:=]\s*[\"']?([A-Za-z0-9_\-./+]{12,})"
)
HARD_PATTERNS = (
    re.compile(r"sk-or-v1-[A-Za-z0-9]{16,}"),
    re.compile(r"sk-[A-Za-z0-9]{32,}"),
    re.compile(r"AKIA[0-9A-Z]{16}"),
    re.compile(r"gh[pousr]_[A-Za-z0-9]{20,}"),
    re.compile(r"AIza[0-9A-Za-z\-_]{35}"),
    re.compile(r"-----BEGIN [A-Z ]*PRIVATE KEY-----"),
)
SCAN_SUFFIXES = {".dart", ".yaml", ".yml", ".json", ".gradle", ".properties", ".md", ".xml", ".kt", ".py", ".sh", ".example", ".lock"}

def published_files() -> tuple[list[Path], bool]:
    """Files that would be published: the Git index, or the tree before git init.

    Only tracked files matter for a public repository, and the index is the
    authoritative list. Outside a work tree the tree is walked instead, skipping
    artifacts that every local Flutter run regenerates.
    """
    try:
        result = subprocess.run(
            ["git", "ls-files", "-z"], cwd=ROOT, capture_output=True, check=True
        )
    except (OSError, subprocess.CalledProcessError):
        regenerated = {"local.properties"}
        paths = [
            path
            for path in sorted(ROOT.rglob("*"))
            if path.is_file()
            and not any(part in IGNORED_DIRS for part in path.parts)
            and path.name not in regenerated
        ]
        print("note: not a Git work tree; scanning the directory tree instead")
        return paths, False
    paths = [ROOT / name for name in result.stdout.decode("utf-8").split("\0") if name]
    return sorted(paths), True


published, is_work_tree = published_files()

scanned = 0
placeholders = 0
for path in published:
    if not path.is_file() or any(part in IGNORED_DIRS for part in path.parts):
        continue
    relative = path.relative_to(ROOT).as_posix()
    name = path.name
    lower = name.lower()

    check(name not in FORBIDDEN_NAMES, f"local configuration file must not be committed: {relative}")
    check(
        path.suffix.lower() not in FORBIDDEN_SUFFIXES,
        f"keystore-like file must not be committed: {relative}",
    )
    if lower.startswith(".env") and not lower.endswith(".example"):
        failures.append(f"real environment file must not be committed: {relative}")
        continue
    if lower.startswith(".env") and not lower.endswith(".example"):
        failures.append(f"real environment file must not be committed: {relative}")
        continue

    if path.suffix.lower() not in SCAN_SUFFIXES:
        continue
    try:
        text = path.read_text(encoding="utf-8")
    except UnicodeDecodeError:
        continue
    scanned += 1

    for pattern in HARD_PATTERNS:
        match = pattern.search(text)
        if match:
            failures.append(f"credential-like literal in {relative}: {pattern.pattern}")

    for match in ASSIGNMENT.finditer(text):
        value = match.group(2)
        upper = value.upper()
        if any(marker in upper for marker in PLACEHOLDER_MARKERS):
            placeholders += 1
            continue
        failures.append(
            f"possible real credential assignment in {relative}: {match.group(1)}"
        )

check(scanned > 0, "credential scan found no readable files")

# --- Licensing package ---------------------------------------------------------

for relative in (
    "data/README.md",
    "data/catalog/seed_places.json",
    "data/catalog/README.md",
    "data/datasets/README.md",
    "docs/THIRD_PARTY_ATTRIBUTIONS.md",
    "docs/PRIVACY.md",
    "docs/KNOWN_LIMITATIONS.md",
    "docs/LICENSING.md",
    "docs/BUILDING.md",
    "docs/CONFIGURATION.md",
    "docs/ARCHITECTURE.md",
    "docs/BRANDING.md",
):
    check((ROOT / relative).is_file(), f"missing release document: {relative}")

catalog_notice = read("data/catalog/README.md")
for marker in ("OpenStreetMap", "ODbL", "opendatacommons.org/licenses/odbl/1-0/"):
    check(marker in catalog_notice, f"catalog notice is missing {marker}")

# --- Report --------------------------------------------------------------------

print(f"release snapshot checks: {checked} assertions, {scanned} files scanned")
print(f"synthetic placeholders classified (not secrets): {placeholders}")
if failures:
    print(f"\nFAILED ({len(failures)}):")
    for failure in failures:
        print(f"  - {failure}")
    sys.exit(1)

print("OK: no findings")
