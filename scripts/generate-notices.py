#!/usr/bin/env python3
"""Generates the third-party license notices shipped in the apps.

    scripts/generate-notices.py mac     OUT.json   # Rust core (Apple, with the drive feature) + scrcpy
    scripts/generate-notices.py android OUT.json   # Rust core (Android) + the app's Gradle libraries

Output: {"components": [{name, version, license, homepage, text}], "texts": {id: full text}}.
Only what is linked into the app is listed: normal (non-dev, non-build) dependencies of brege-ffi
for the target platform.
"""

import glob
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import xml.etree.ElementTree as ET

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CORE = os.path.join(ROOT, "core")
CARGO = shutil.which("cargo") or os.path.expanduser("~/.cargo/bin/cargo")

# C libraries compiled into crates, whose licenses the crate metadata does not describe.
BUNDLED_C = {
    "libsqlite3-sys": [("SQLCipher", "BSD-3-Clause", "https://www.zetetic.net/sqlcipher/"),
                       ("SQLite", "Public domain", "https://sqlite.org/copyright.html")],
    "openssl-src": [("OpenSSL", "Apache-2.0", "https://www.openssl.org/source/license.html")],
}


def license_text(directory):
    files = sorted(f for f in glob.glob(os.path.join(directory, "*"))
                   if re.match(r"(LICEN[CS]E|COPYING|NOTICE|UNLICENSE)", os.path.basename(f), re.I) and os.path.isfile(f))
    parts = []
    for f in files:
        try:
            parts.append(open(f, encoding="utf-8", errors="replace").read().strip())
        except OSError:
            pass
    return "\n\n".join(parts)


MIT_TEXT = """Permission is hereby granted, free of charge, to any person obtaining a copy of this software and
associated documentation files (the "Software"), to deal in the Software without restriction, including
without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the
following conditions:

The above copyright notice and this permission notice shall be included in all copies or substantial
portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT
LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO
EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER
IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE
USE OR OTHER DEALINGS IN THE SOFTWARE."""


def standard_text(license, authors, templates):
    """For crates without license files: the standard text of (the first of) their licenses."""
    ids = re.findall(r"[A-Za-z0-9.\-]+", license or "")
    owner = ", ".join(a.split("<")[0].strip() for a in authors) or "the authors"
    for lid in ids:
        if lid == "MIT":
            return f"Copyright (c) {owner}\n\n{MIT_TEXT}"
        if lid in templates:
            return f"Copyright (c) {owner}\n\n{templates[lid]}"
    spdx = ids[0] if ids else "unknown"
    return f"Copyright (c) {owner}\nLicensed under {license}. License text: https://spdx.org/licenses/{spdx}.html"


def harvest_templates(directories):
    """Full Apache-2.0 and MPL-2.0 texts, taken from crates that ship them."""
    templates = {}
    for d in directories:
        for f in glob.glob(os.path.join(d, "*")):
            base = os.path.basename(f).upper()
            try:
                body = open(f, encoding="utf-8", errors="replace").read()
            except (OSError, IsADirectoryError):
                continue
            if "Apache-2.0" not in templates and "APACHE" in base and "Apache License" in body and "Version 2.0" in body:
                templates["Apache-2.0"] = body.strip()
            if "MPL-2.0" not in templates and "Mozilla Public License Version 2.0" in body:
                templates["MPL-2.0"] = body.strip()
    return templates


class Notices:
    def __init__(self):
        self.components = []
        self.texts = {}

    def add(self, name, version, license, homepage, text):
        text_id = None
        if text:
            text_id = hashlib.sha1(text.encode()).hexdigest()[:12]
            self.texts[text_id] = text
        self.components.append({"name": name, "version": version, "license": license or "See text",
                                "homepage": homepage or "", "text": text_id})

    def write(self, path):
        seen, unique = set(), []
        for c in sorted(self.components, key=lambda c: c["name"].lower()):
            key = (c["name"].lower(), c["version"])
            if key not in seen:
                seen.add(key)
                unique.append(c)
        os.makedirs(os.path.dirname(os.path.abspath(path)), exist_ok=True)
        json.dump({"components": unique, "texts": self.texts}, open(path, "w"), indent=1, ensure_ascii=False)
        print(f"{len(unique)} components -> {path}")


def rust(notices, target, features):
    cmd = [CARGO, "metadata", "--format-version", "1", "--filter-platform", target] + features
    meta = json.loads(subprocess.run(cmd, cwd=CORE, capture_output=True, text=True, check=True).stdout)
    packages = {p["id"]: p for p in meta["packages"]}
    nodes = {n["id"]: n for n in meta["resolve"]["nodes"]}
    workspace = set(meta["workspace_members"])
    start = next(i for i in workspace if packages[i]["name"] == "brege-ffi")
    stack, linked = [start], set()
    while stack:
        node = nodes[stack.pop()]
        for dep in node["deps"]:
            if any(k["kind"] is None for k in dep["dep_kinds"]) and dep["pkg"] not in linked:
                linked.add(dep["pkg"])
                stack.append(dep["pkg"])
    directories = [os.path.dirname(packages[pid]["manifest_path"]) for pid in linked]
    templates = harvest_templates(directories)
    for pid in linked - workspace:
        p = packages[pid]
        directory = os.path.dirname(p["manifest_path"])
        text = license_text(directory) or standard_text(p["license"], p.get("authors", []), templates)
        notices.add(p["name"], p["version"], p["license"], p.get("homepage") or p.get("repository"), text)
        for name, lic, url in BUNDLED_C.get(p["name"], []):
            notices.add(name, "bundled with " + p["name"], lic, url, license_text(directory))


def gradle(notices):
    android = os.path.join(ROOT, "android")
    out = subprocess.run(["./gradlew", "-q", ":app:dependencies", "--configuration", "releaseRuntimeClasspath"],
                         cwd=android, capture_output=True, text=True, check=True).stdout
    coords = set()
    for line in out.splitlines():
        m = re.search(r"--- ([\w.\-]+):([\w.\-]+):([\w.\-]+)(?: -> ([\w.\-]+))?", line)
        if m and "(*)" not in line or m and line.rstrip().endswith("(*)"):
            if m:
                coords.add((m.group(1), m.group(2), m.group(4) or m.group(3)))
    cache = os.path.expanduser("~/.gradle/caches/modules-2/files-2.1")
    for group, artifact, version in sorted(coords):
        poms = glob.glob(os.path.join(cache, group, artifact, version, "*", f"{artifact}-{version}.pom"))
        name, url, homepage = None, None, None
        if poms:
            try:
                tree = ET.parse(poms[0])
                ns = {"m": tree.getroot().tag.split("}")[0].strip("{")} if tree.getroot().tag.startswith("{") else {}
                find = (lambda e, q: e.find("m:" + q.replace("/", "/m:"), ns)) if ns else (lambda e, q: e.find(q))
                lic = find(tree.getroot(), "licenses/license")
                if lic is not None:
                    name = (find(lic, "name").text if find(lic, "name") is not None else None)
                    url = (find(lic, "url").text if find(lic, "url") is not None else None)
                home = find(tree.getroot(), "url")
                homepage = home.text if home is not None else None
            except ET.ParseError:
                pass
        if group.startswith("com.google.android.gms") and not name:
            name, url = "Android Software Development Kit License", "https://developer.android.com/studio/terms"
        text = f"{name}\n{url}" if name and url else (name or "")
        notices.add(f"{group}:{artifact}", version, name, homepage or url, text)


def main():
    platform, out = sys.argv[1], sys.argv[2]
    notices = Notices()
    if platform == "mac":
        rust(notices, "aarch64-apple-darwin", ["--features", "brege-ffi/drive"])
        scrcpy = os.path.join(ROOT, "macos", "ThirdParty", "scrcpy")
        notices.add("scrcpy (server)", "4.1", "Apache-2.0", "https://github.com/Genymobile/scrcpy", license_text(scrcpy))
    elif platform == "android":
        rust(notices, "aarch64-linux-android", [])
        gradle(notices)
    else:
        sys.exit("platform must be mac or android")
    notices.write(out)


if __name__ == "__main__":
    main()
