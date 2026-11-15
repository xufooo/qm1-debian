#!/usr/bin/env python3
"""List newc initramfs entries, including early cpio plus compressed archives."""
import gzip
import lzma
from pathlib import Path
import subprocess
import sys


def list_entries(data):
    while data:
        data = data.lstrip(b"\0")
        if not data:
            return
        if data.startswith(b"\x28\xb5\x2f\xfd"):
            data = subprocess.run(["zstd", "-dc"], input=data,
                                  stdout=subprocess.PIPE, check=True).stdout
        elif data.startswith(b"\x1f\x8b"):
            data = gzip.decompress(data)
        elif data.startswith(b"\xfd7zXZ\0"):
            data = lzma.decompress(data)
        position = 0
        while True:
            header = data[position:position + 110]
            if len(header) != 110 or header[:6] not in (b"070701", b"070702"):
                raise ValueError("invalid or unsupported newc archive header")
            fields = [int(header[i:i + 8], 16) for i in range(6, 110, 8)]
            size, namesize = fields[6], fields[11]
            start = position + 110
            name = data[start:start + namesize]
            if not namesize or len(name) != namesize or not name.endswith(b"\0"):
                raise ValueError("invalid newc entry name")
            name = name[:-1].decode()
            content = (start + namesize + 3) & ~3
            if content + size > len(data):
                raise ValueError("truncated newc entry")
            position = (content + size + 3) & ~3
            if name == "TRAILER!!!":
                data = data[position:]
                break
            yield name


if __name__ == "__main__":
    try:
        for entry in list_entries(Path(sys.argv[1]).read_bytes()):
            print(entry)
    except (ValueError, OSError, EOFError, subprocess.CalledProcessError) as error:
        sys.exit(f"cannot list initramfs: {error}")
