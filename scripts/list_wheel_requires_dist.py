#!/usr/bin/env python3
"""Print Requires-Dist lines from any wheel's METADATA (PEP 643).

Works for HTTP(S) URLs to .whl files (uses range reads; no full download).

Example:
  %(prog)s 'https://packages.redhat.com/.../some-package-1.0-cp312-cp312-linux_x86_64.whl'
"""

from __future__ import annotations

import argparse
import struct
import sys
import urllib.request
import zlib


def _http_range(url: str, start: int, end: int) -> bytes:
    req = urllib.request.Request(url)
    req.add_header("Range", f"bytes={start}-{end}")
    with urllib.request.urlopen(req, timeout=120) as r:
        return r.read()


def _read_metadata_from_wheel(url: str) -> str:
    with urllib.request.urlopen(urllib.request.Request(url), timeout=60) as r:
        final = r.geturl()
        total = int(r.headers["Content-Length"])
    tail = _http_range(final, total - 70_000, total - 1)
    eocd_i = tail.rfind(b"PK\x05\x06")
    cd_off = struct.unpack_from("<I", tail, eocd_i + 16)[0]
    cd_size = struct.unpack_from("<I", tail, eocd_i + 12)[0]
    cd = _http_range(final, cd_off, cd_off + cd_size - 1)
    pos = 0
    while pos + 46 <= len(cd):
        if struct.unpack_from("<I", cd, pos)[0] != 0x02014B50:
            break
        fn_len = struct.unpack_from("<H", cd, pos + 28)[0]
        ex_len = struct.unpack_from("<H", cd, pos + 30)[0]
        cm_len = struct.unpack_from("<H", cd, pos + 32)[0]
        fn = cd[pos + 46 : pos + 46 + fn_len].decode("utf-8", errors="replace")
        if fn.endswith("METADATA") and "dist-info" in fn:
            loff = struct.unpack_from("<I", cd, pos + 42)[0]
            csz = struct.unpack_from("<I", cd, pos + 20)[0]
            meth = struct.unpack_from("<H", cd, pos + 10)[0]
            hdr = _http_range(final, loff, loff + 30 + 512)
            fnl = struct.unpack_from("<H", hdr, 26)[0]
            exl = struct.unpack_from("<H", hdr, 28)[0]
            ds = loff + 30 + fnl + exl
            raw = _http_range(final, ds, ds + csz - 1)
            if meth == 0:
                return raw.decode("utf-8", errors="replace")
            return zlib.decompressobj(-zlib.MAX_WBITS).decompress(raw).decode("utf-8", errors="replace")
        pos = pos + 46 + fn_len + ex_len + cm_len
    raise RuntimeError("METADATA not found in wheel")


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument(
        "wheel_url",
        help="HTTP(S) URL to a .whl (redirects followed)",
    )
    args = p.parse_args()
    try:
        meta = _read_metadata_from_wheel(args.wheel_url)
    except Exception as e:
        print(f"error: {e}", file=sys.stderr)
        return 1
    for line in meta.splitlines():
        if line.startswith("Requires-Dist:"):
            print(line)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
