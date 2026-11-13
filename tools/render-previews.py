#!/usr/bin/env python3
"""Render README previews from the real SwiftUI views using isolated, synthetic state."""
from pathlib import Path
import os
import shutil
import subprocess

ROOT = Path(__file__).resolve().parents[1]
WORK = ROOT / "build/docs-preview"


def main():
    WORK.mkdir(parents=True, exist_ok=True)
    # Compile a disposable copy so the installed app, its signing, and its settings stay untouched.
    for name in ("macos", "shared"):
        target = WORK / name
        if target.exists():
            shutil.rmtree(target)
        shutil.copytree(ROOT / name, target)
    (WORK / "macos/App/DeskIsleApp.swift").unlink()
    shutil.copy2(ROOT / "tools/previews/PreviewMain.swift", WORK / "macos/PreviewMain.swift")
    # PreviewMain injects a temporary layout library; production initialization no longer reads legacy wallpaper.
    manifest = (ROOT / "Package.swift").read_text()
    manifest = manifest.replace(',\n        .testTarget(name: "DeskIsleTests", dependencies: ["DeskIsle"], path: "tests/macos")', '')
    (WORK / "Package.swift").write_text(manifest)
    shutil.copy2(ROOT / "Package.resolved", WORK / "Package.resolved")
    env = os.environ.copy()
    checkout = ROOT / "build/swiftpm/checkouts/miucs"
    if not env.get("MIUCS_LOCAL_PATH") and checkout.is_dir():
        env["MIUCS_LOCAL_PATH"] = str(checkout)
    subprocess.run(["swift", "build", "--package-path", str(WORK), "--product", "DeskIsle"], env=env, check=True)
    binary = subprocess.check_output(["swift", "build", "--package-path", str(WORK), "--show-bin-path"], env=env, text=True).strip()
    subprocess.run([str(Path(binary) / "DeskIsle"), str(ROOT / "docs/images")], check=True)


if __name__ == "__main__":
    main()
