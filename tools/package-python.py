#!/usr/bin/env python3
"""Bundle the relocatable uv-managed CPython runtime, retaining its licenses."""
import argparse
import json
from pathlib import Path
import shutil
import subprocess


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--python", type=Path, required=True)
    parser.add_argument("--destination", type=Path, required=True)
    args = parser.parse_args()
    source = Path(subprocess.check_output([str(args.python), "-I", "-c", "import sys;print(sys.prefix)"], text=True).strip()).resolve()
    if not (source / "bin/python3.11").is_file() or not (source / "lib/python3.11/LICENSE.txt").is_file():
        raise SystemExit("需要 uv 管理的可重定位 CPython 3.11 运行环境。")
    destination = args.destination.absolute()
    if (destination.is_symlink() or source == destination.resolve()
            or source in destination.resolve().parents or destination.resolve() in source.parents):
        raise SystemExit("无效的 Python 打包目标。")
    if destination.exists():
        shutil.rmtree(destination)
    shutil.copytree(source, destination, symlinks=True)
    probe = subprocess.check_output([str(destination / "bin/python3.11"), "-I", "-c",
                                     "import sys,ssl,sqlite3,json;print(json.dumps({'prefix':sys.prefix,'version':sys.version_info[:2]}))"],
                                    text=True)
    result = json.loads(probe)
    if Path(result["prefix"]).resolve() != destination.resolve() or result["version"] != [3, 11]:
        raise SystemExit("Python 运行环境无法随应用移动。")
    print("Bundled CPython 3.11: relocation and SSL/SQLite imports verified")


if __name__ == "__main__":
    main()
