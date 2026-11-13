"""Native widget regression tests. Requires ESP-IDF's cJSON source, but no board."""
import hashlib
import os
from pathlib import Path
import subprocess
import tempfile
import zlib

ROOT = Path(__file__).resolve().parents[1]


def main():
    idf = os.environ.get("IDF_PATH")
    if not idf:
        raise SystemExit("Load ESP-IDF's export.sh first (IDF_PATH is required for cJSON).")
    cjson = Path(idf) / "components/json/cJSON"
    sources = ["main/widgets/widget.c", "main/widgets/widget_paint.c", "main/widgets/mac_load.c",
               "main/widgets/codex.c", "main/widgets/garmin.c", "main/widgets/bluetooth.c",
               "main/widgets/notification.c", "shared/frosted.c", "shared/layout.c", "tests/widget_test.c"]
    with tempfile.TemporaryDirectory() as directory:
        temp = Path(directory)
        font = temp / "font.bin"
        font.write_bytes(zlib.decompress((ROOT / "resources/widget_font.bin").read_bytes()[4:]))
        executable = temp / "widgets"
        # cJSON uses sprintf internally; suppress the macOS SDK deprecation only for this dependency.
        cjson_object = temp / "cjson.o"
        subprocess.run(["clang", "-std=c11", "-fsanitize=address,undefined", "-Wno-deprecated-declarations",
                        "-c", str(cjson / "cJSON.c"), "-o", str(cjson_object)], check=True)
        subprocess.run(["clang", "-std=c11", "-Wall", "-Wextra", "-Werror", "-fsanitize=address,undefined",
                        "-I", "main/widgets", "-I", "main/transport", "-I", "shared/include", "-I", str(cjson),
                        *sources, str(cjson_object), "-o", str(executable)], cwd=ROOT, check=True)
        result = subprocess.check_output([str(executable), str(font)])
        expected = (ROOT / "tests/fixtures/widget-render.sha256").read_text().strip()
        assert hashlib.sha256(result).hexdigest() == expected, "Widget pixels, alpha, dirty bounds or timing changed"
        print(f"PASS {len(result.splitlines())} native widget frames match pre-refactor output; ASan/UBSan clean")


if __name__ == "__main__":
    main()
