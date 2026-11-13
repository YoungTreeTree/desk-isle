"""Native GIF player lifecycle and malformed-resource tests, with ASan/UBSan."""
from pathlib import Path
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory() as directory:
    executable = Path(directory) / "picture-test"
    subprocess.run(["clang", "-std=c11", "-Wall", "-Wextra", "-Werror", "-fsanitize=address,undefined",
                    "-I", "main/pictures", "-I", "main/transport", "-I", "shared/include",
                    "main/pictures/picture_pack.c", "main/pictures/picture_player.c",
                    "main/transport/protocol.c", "shared/layout.c", "tests/picture_test.c", "-o", str(executable)],
                   cwd=ROOT, check=True)
    subprocess.run([str(executable), *sys.argv[1:]], check=True)
