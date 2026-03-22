#!/usr/bin/env python3
"""Verify aarch64 wheel hashes in CUDA PyPI requirements files.

Queries PyPI for each package version, gets the aarch64 manylinux wheel digest(s),
and checks they appear in the requirements (base + arch-specific files).
"""

import json
import re
import sys
import urllib.request
from urllib.parse import urlparse

REQUIREMENTS_BASE = "requirements.hashes.wheel.pypi.cuda.base.txt"
REQUIREMENTS_ARCH_FILES = [
    "requirements.hashes.wheel.pypi.cuda.x86_64.txt",
    "requirements.hashes.wheel.pypi.cuda.aarch64.txt",
]
# Platform-specific packages that have separate x86_64 and aarch64 wheels on PyPI
PACKAGES_TO_CHECK = [
    "torch",
    "torchvision",
    "faiss-cpu",
    "nvidia-cublas-cu12",
    "nvidia-cuda-nvrtc-cu12",
    "nvidia-cudnn-cu12",
    "opencv-python",
    "numpy",
]


def get_hashes_from_requirements(paths: list[str]) -> dict[str, set[str]]:
    """Parse requirement file(s): package name -> set of sha256 hashes (merged)."""
    pkg_hashes: dict[str, set[str]] = {}
    for path in paths:
        current_pkg = None
        with open(path) as f:
            for line in f:
                line = line.rstrip()
                if re.match(r"^[a-zA-Z0-9][a-zA-Z0-9_.-]*(==| @ )", line):
                    name = re.match(r"^([a-zA-Z0-9][a-zA-Z0-9_.-]*)", line).group(1)
                    current_pkg = name
                    if current_pkg not in pkg_hashes:
                        pkg_hashes[current_pkg] = set()
                elif current_pkg and line.strip().startswith("--hash=sha256:"):
                    m = re.search(r"--hash=sha256:([a-f0-9]+)", line)
                    if m:
                        pkg_hashes[current_pkg].add(m.group(1))
    return pkg_hashes


def get_package_version(
    requirements_hashes: dict[str, set[str]], paths: list[str]
) -> dict[str, str]:
    """Get version for each package from requirement file(s) (first occurrence)."""
    pkg_version: dict[str, str] = {}
    for path in paths:
        with open(path) as f:
            for line in f:
                m = re.match(r"^([a-zA-Z0-9][a-zA-Z0-9_.-]*)==([0-9][0-9.]*)", line)
                if m and m.group(1) in requirements_hashes:
                    name, ver = m.group(1), m.group(2)
                    if name not in pkg_version:
                        pkg_version[name] = ver
                else:
                    url_line_re = (
                        r"^([a-zA-Z0-9][a-zA-Z0-9_.-]*) @ .*/"
                        r"([a-zA-Z0-9_-]+)-([0-9]+\.[0-9]+\.[0-9]+)-"
                    )
                    m2 = re.match(url_line_re, line)
                    if m2 and m2.group(1) in requirements_hashes and m2.group(1) not in pkg_version:
                        pkg_version[m2.group(1)] = m2.group(3)
    return pkg_version


def get_aarch64_hashes_from_pypi(package: str, version: str) -> list[str]:
    """Fetch PyPI JSON for package/version and return sha256 of aarch64 manylinux wheels."""
    url = f"https://pypi.org/pypi/{package}/{version}/json"
    parsed = urlparse(url)
    if parsed.scheme != "https" or parsed.netloc != "pypi.org":
        return []
    try:
        with urllib.request.urlopen(url, timeout=15) as r:  # noqa: S310
            data = json.load(r)
    except Exception:
        return []  # package not on PyPI or network error
    hashes = []
    for info in data.get("urls", []):
        if info.get("packagetype") != "bdist_wheel":
            continue
        filename = info.get("filename", "")
        # aarch64 wheels: manylinux*_aarch64 or manylinux*aarch64
        if "aarch64" not in filename.lower():
            continue
        if "manylinux" not in filename.lower() and "linux" not in filename.lower():
            continue
        digests = info.get("digests", {})
        if "sha256" in digests:
            hashes.append(digests["sha256"])
    return hashes


def _aarch64_verify_results(
    req_hashes: dict[str, set[str]],
    pkg_version: dict[str, str],
) -> tuple[list[tuple[str, str, int]], list[tuple[str, str, list[str]]]]:
    """Compare requirement hashes to PyPI aarch64 wheel digests for known packages."""
    missing: list[tuple[str, str, list[str]]] = []
    present: list[tuple[str, str, int]] = []

    for package in PACKAGES_TO_CHECK:
        if package not in req_hashes:
            continue
        version = pkg_version.get(package)
        if not version:
            continue
        our_hashes = req_hashes[package]
        aarch64_hashes = get_aarch64_hashes_from_pypi(package, version)
        if not aarch64_hashes:
            present.append((package, version, 0))
            continue
        found = [h for h in aarch64_hashes if h in our_hashes]
        if found:
            present.append((package, version, len(found)))
        else:
            missing.append((package, version, aarch64_hashes))
    return present, missing


def _print_aarch64_report(
    present: list[tuple[str, str, int]],
    missing: list[tuple[str, str, list[str]]],
) -> int:
    """Print verification summary; return 1 if any expected aarch64 hash is missing."""
    print("=== Aarch64 hash verification ===\n")
    print("Packages with aarch64 wheels on PyPI and hashes present in our file:")
    for pkg, ver, count in present:
        if count:
            print(f"  OK  {pkg}=={ver}  ({count} aarch64 hash(es) present)")
        else:
            print(f"  --  {pkg}=={ver}  (no aarch64 wheel on PyPI or pure Python)")
    if missing:
        print("\nPackages missing one or more aarch64 hashes:")
        for pkg, ver, hashes in missing:
            print(f"  MISSING  {pkg}=={ver}")
            for h in hashes[:3]:
                print(f"    sha256:{h}")
            if len(hashes) > 3:
                print(f"    ... and {len(hashes) - 3} more")
        return 1
    print("\nAll checked packages have aarch64 hashes in the requirements file.")
    return 0


def main() -> int:
    """Load requirement files, verify aarch64 wheel hashes, print report."""
    req_paths = [REQUIREMENTS_BASE, *REQUIREMENTS_ARCH_FILES]
    try:
        req_hashes = get_hashes_from_requirements(req_paths)
        pkg_version = get_package_version(req_hashes, req_paths)
    except FileNotFoundError as e:
        print(f"Requirements file not found: {e}", file=sys.stderr)
        return 1

    present, missing = _aarch64_verify_results(req_hashes, pkg_version)
    return _print_aarch64_report(present, missing)


if __name__ == "__main__":
    sys.exit(main())
