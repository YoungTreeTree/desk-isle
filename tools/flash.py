#!/usr/bin/env python3
"""Back up and update the factory app, with an explicit migration to the 8 MiB partition."""
import argparse
from contextlib import contextmanager
from datetime import datetime
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import stat
import struct
import subprocess
import sys
import time

TABLE_OFFSET = 0x8000
TABLE_SECTOR = 0x1000
APP_OFFSET = 0x10000
LEGACY_SIZE = 0x100000
EXPANDED_SIZE = 0x800000
PARTITION = struct.Struct("<HBBII16sI")


@contextmanager
def reserve_ch343():
    """Ask the running Mac relay to close CH343, then keep it free until flashing ends."""
    directory = Path.home() / "Library/Caches/com.deskisle.layout/uart"
    directory.mkdir(parents=True, exist_ok=True, mode=0o700)
    info = directory.lstat()
    if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077:
        raise SystemExit("Unsafe DeskIsle UART directory")
    flags = os.O_CREAT | os.O_RDWR | os.O_CLOEXEC | os.O_NOFOLLOW
    flash = os.open(directory / "flash.lock", flags, 0o600)
    try:
        try:
            fcntl.flock(flash, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise SystemExit("DeskIsle is already being flashed. Retry when the port is free.") from None
        owner = os.open(directory / "port.lock", flags, 0o600)
        try:
            deadline = time.monotonic() + 5
            while True:
                try:
                    fcntl.flock(owner, fcntl.LOCK_EX | fcntl.LOCK_NB)
                    break
                except BlockingIOError:
                    if time.monotonic() >= deadline:
                        raise SystemExit("The DeskIsle app did not release CH343. Quit it and retry.") from None
                    time.sleep(0.05)
            yield
        finally:
            os.close(owner)
    finally:
        os.close(flash)


def factory_size(table):
    """Accept the two known layouts and verify the ESP-IDF table checksum."""
    if len(table) not in (0xC00, TABLE_SECTOR):
        raise SystemExit("Unexpected partition table length")
    entries = []
    for offset in range(0, len(table), PARTITION.size):
        row = table[offset:offset + PARTITION.size]
        if row[:16] == b"\xeb\xeb" + b"\xff" * 14:
            if row[16:] == hashlib.md5(table[:offset]).digest() and all(
                byte == 0xff for byte in table[offset + PARTITION.size:]
            ):
                break
            raise SystemExit("Invalid partition table checksum or padding")
        magic, kind, subtype, address, size, name, flags = PARTITION.unpack(row)
        if magic != 0x50AA or flags:
            raise SystemExit("Unexpected partition table entry")
        entries.append((kind, subtype, address, size, name.rstrip(b"\0")))
    else:
        raise SystemExit("Partition table checksum missing")

    data_partitions = [(1, 2, 0x9000, 0x6000, b"nvs"), (1, 1, 0xf000, 0x1000, b"phy_init")]
    for size in (LEGACY_SIZE, EXPANDED_SIZE):
        if entries == data_partitions + [(0, 0, APP_OFFSET, size, b"factory")]:
            return size
    raise SystemExit(f"Unexpected DeskIsle partition layout {entries}")


def main():
    root = Path(__file__).resolve().parents[1]
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--port", required=True, help="CH343 programming port, not the DeskIsle data port")
    parser.add_argument("--firmware", type=Path, default=root / "build/desk_isle.bin")
    parser.add_argument("--partition-table", type=Path, help="Migrate the 1 MiB layout to the generated 8 MiB table")
    parser.add_argument("--baud", type=int, default=115200)
    parser.add_argument("--backup-dir", type=Path, default=root / "build/hardware-backups")
    args = parser.parse_args()
    firmware = args.firmware.resolve()
    content = firmware.read_bytes()
    if not content or content[0] != 0xE9:
        raise SystemExit("Not an ESP application image")
    new_table = args.partition_table.read_bytes() if args.partition_table else None
    if new_table is not None and factory_size(new_table) != EXPANDED_SIZE:
        raise SystemExit("Migration requires the 8 MiB DeskIsle table")
    with reserve_ch343():
        flash(args, firmware, content, new_table)


def flash(args, firmware, content, new_table):
    backup = args.backup_dir / datetime.now().strftime("%Y%m%d-%H%M%S-%f")
    backup.mkdir(parents=True, exist_ok=False)
    command = [sys.executable, "-m", "esptool", "--chip", "esp32p4", "--port", args.port,
               "--baud", str(args.baud), "--no-stub"]

    def run(*arguments):
        subprocess.run(command + list(arguments), check=True)

    table_file = backup / "partition-table.bin"
    run("read-flash", hex(TABLE_OFFSET), hex(TABLE_SECTOR), str(table_file))
    table = table_file.read_bytes()
    if len(table) != TABLE_SECTOR:
        raise SystemExit("Incomplete partition table backup; nothing written")
    previous_size = factory_size(table)
    migrating = new_table is not None and previous_size == LEGACY_SIZE
    target_size = EXPANDED_SIZE if migrating else previous_size
    if len(content) > target_size:
        raise SystemExit("Firmware exceeds the factory partition; pass --partition-table to migrate the legacy layout")
    if migrating:
        detected = subprocess.run(command + ["flash-id"], check=True, capture_output=True, text=True)
        print(detected.stdout, end="")
        if not re.search(r"Detected flash size:\s*16\s*MB\b", detected.stdout):
            raise SystemExit("Expected 16 MiB physical flash for the migration; nothing written")
        nvs = backup / "previous-nvs.bin"
        run("read-flash", "0x9000", "0x6000", str(nvs))
        if nvs.stat().st_size != 0x6000:
            raise SystemExit("Incomplete layout settings backup; nothing written")
    previous = backup / "previous-app.bin"
    run("read-flash", hex(APP_OFFSET), hex(previous_size), str(previous))
    previous_bytes = previous.read_bytes()
    if len(previous_bytes) != previous_size:
        raise SystemExit("Incomplete application backup; nothing written")
    manifest = {"port": args.port, "firmware": str(firmware), "sha256": hashlib.sha256(content).hexdigest(),
                "app_offset": hex(APP_OFFSET), "previous_app": str(previous),
                "previous_app_partition_bytes": previous_size, "app_partition_bytes": target_size,
                "previous_partition_table_sha256": hashlib.sha256(table).hexdigest(),
                "previous_app_sha256": hashlib.sha256(previous_bytes).hexdigest(), "flashed": False}
    writes = ["write-flash"]
    if migrating:
        candidate = backup / "new-partition-table.bin"
        candidate.write_bytes(new_table)
        manifest["new_partition_table_sha256"] = hashlib.sha256(new_table).hexdigest()
        manifest["previous_nvs_sha256"] = hashlib.sha256(nvs.read_bytes()).hexdigest()
        writes += [hex(TABLE_OFFSET), str(candidate)]
    # Write the same bytes that were validated, even if another build is running.
    application = backup / "new-app.bin"
    application.write_bytes(content)
    manifest_path = backup / "manifest.json"
    manifest_path.write_text(json.dumps(manifest, indent=2))
    run(*writes, hex(APP_OFFSET), str(application))
    manifest["flashed"] = True
    manifest_path.write_text(json.dumps(manifest, indent=2))
    print(f"Flashed and verified. Previous application: {backup / 'previous-app.bin'}")


if __name__ == "__main__":
    main()
