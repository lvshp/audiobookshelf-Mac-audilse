#!/usr/bin/env python3
"""Pinned VLC source review materials; deliberately not a release-compliance certificate.

Only fetch/contrib access the network. No build, signing, app mutation or source commit.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import shutil
import subprocess
import sys
import tarfile
import tempfile
from urllib.parse import urlparse

PROJECT = Path(__file__).resolve().parents[1]
LOCK_PATH = PROJECT / "Packaging/VLC/source-lock.json"
LOCK = json.loads(LOCK_PATH.read_text())
ALLOWED_HOSTS = {"codeload.github.com", "download.videolan.org"}


def digest(path, algorithm="sha256"):
    result = hashlib.new(algorithm)
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            result.update(chunk)
    return result.hexdigest()


def regular(path):
    if path.is_symlink() or not path.is_file():
        raise ValueError("Expected regular file: " + str(path))


def checked(path, expected, algorithm="sha256"):
    regular(path)
    if digest(path, algorithm) != expected:
        raise ValueError("Checksum mismatch: " + str(path))


def write_json(path, data):
    path.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile("w", dir=path.parent, delete=False) as target:
        json.dump(data, target, ensure_ascii=False, indent=2, sort_keys=True)
        target.write("\n")
        temporary = Path(target.name)
    temporary.replace(path)


def download(url, path, expected, algorithm="sha256"):
    parsed = urlparse(url)
    if parsed.scheme != "https" or parsed.hostname not in ALLOWED_HOSTS or parsed.username or parsed.password:
        raise ValueError("Not an allowed official HTTPS source")
    if path.exists() or path.is_symlink():
        checked(path, expected, algorithm)
        print("CACHED", path.name)
        return
    path.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(dir=path.parent, delete=False) as target:
        temporary = Path(target.name)
    try:
        # No redirects: these fixed official endpoints return their archives directly.
        subprocess.run(["curl", "--disable", "--fail", "--silent", "--show-error", "--proto", "=https",
                        "--connect-timeout", "20", "--max-time", "300", "--max-filesize", "268435456",
                        "--output", str(temporary), url], check=True)
        checked(temporary, expected, algorithm)
        temporary.replace(path)
    finally:
        temporary.unlink(missing_ok=True)
    print("FETCHED", path.name, path.stat().st_size)


def source_archives(output):
    for item in LOCK["sources"]:
        checked(output / "archives" / item["filename"], item["sha256"])


def extract_archive(archive, destination):
    """Strip one pinned archive root; reject traversal, devices and escaping links."""
    with tarfile.open(archive) as source:
        members = source.getmembers()
        roots = {PurePosixPath(m.name).parts[0] for m in members if m.name}
        if len(roots) != 1:
            raise ValueError("Archive must have one root")
        links = []
        for member in members:
            parts = PurePosixPath(member.name).parts
            if not parts or member.name.startswith("/") or ".." in parts:
                raise ValueError("Unsafe archive path")
            relative = Path(*parts[1:])
            if not relative.parts:
                continue
            target = destination / relative
            if member.isdir():
                target.mkdir(parents=True, exist_ok=True)
            elif member.isfile():
                target.parent.mkdir(parents=True, exist_ok=True)
                with source.extractfile(member) as original, target.open("xb") as copied:
                    shutil.copyfileobj(original, copied)
                target.chmod(0o755 if member.mode & 0o111 else 0o644)
            elif member.issym():
                link = PurePosixPath(member.linkname)
                resolved = (target.parent / member.linkname).resolve()
                if link.is_absolute() or not resolved.is_relative_to(destination.resolve()):
                    raise ValueError("Escaping archive symlink")
                links.append((target, member.linkname))
            else:
                raise ValueError("Unsupported archive entry")
        # Create links last so no archived file can be written through one.
        for target, link in links:
            target.parent.mkdir(parents=True, exist_ok=True)
            target.symlink_to(link)


def tree_hashes(directory):
    result = {}
    for path in sorted(directory.rglob("*")):
        relative = path.relative_to(directory)
        if ".git" in relative.parts:
            continue
        if path.is_symlink():
            result[str(relative)] = {"symlink": os.readlink(path)}
        elif path.is_file():
            result[str(relative)] = {"sha256": digest(path), "executable": bool(path.stat().st_mode & 0o111)}
    return result


def contrib_catalog(vlc):
    packages = []
    for sums in sorted((vlc / "contrib/src").glob("*/SHA*SUMS")):
        algorithm = sums.name.removesuffix("SUMS").lower()
        if algorithm not in {"sha512", "sha256", "sha1"}:
            raise ValueError("Unknown upstream checksum algorithm")
        for line in sums.read_text().splitlines():
            if not line.strip() or line.lstrip().startswith("#"):
                continue
            match = re.fullmatch(r"([a-fA-F0-9]+)\s+\*?([^/\s]+)", line.strip())
            if not match or len(match[1]) != hashlib.new(algorithm).digest_size * 2:
                raise ValueError("Unrecognized upstream checksum line: " + str(sums))
            filename = match[2]
            if filename in {".", ".."} or not re.fullmatch(r"[A-Za-z0-9._+-]+", filename):
                raise ValueError("Unsafe contrib filename")
            package = sums.parent.name
            packages.append({"package": package, "filename": filename, "algorithm": algorithm,
                             "checksum": match[1].lower(), "upstreamSums": str(sums.relative_to(vlc)),
                             "url": LOCK["contribMirror"] + "/" + package + "/" + filename})
    return {"actuallyLinkedComponents": False, "description": "All patched-tree checksum candidates, not the selected macOS build set.",
            "archives": packages}


def prepare(output):
    source_archives(output)
    prepared = output / "prepared"
    if prepared.exists() or prepared.is_symlink():
        raise ValueError("Prepared tree already exists; verify it or use a new output directory")
    with tempfile.TemporaryDirectory(prefix="prepare-", dir=output) as temporary:
        stage = Path(temporary)
        for item in LOCK["sources"]:
            destination = stage / item["name"]
            destination.mkdir()
            extract_archive(output / "archives" / item["filename"], destination)
        vlckit, vlc = stage / "vlckit", stage / "vlc"
        script = (vlckit / "buildMobileVLCKit.sh").read_text()
        if 'TESTEDHASH="' + LOCK["sources"][1]["commit"][:8] + '"' not in script:
            raise ValueError("Official build script changed its VLC base")
        patches = sorted((vlckit / "libvlc/patches").glob("*.patch"))
        if len(patches) != LOCK["upstreamPatchCount"]:
            raise ValueError("Unexpected upstream patch count")
        # Apply file changes without manufacturing commits or executing upstream build code.
        git_env = {key: value for key, value in os.environ.items() if not key.startswith("GIT_")}
        git_env.update(GIT_CONFIG_NOSYSTEM="1", GIT_CONFIG_GLOBAL="/dev/null")
        subprocess.run(["git", "-C", str(vlc), "init", "-q"], check=True, env=git_env)
        for patch in patches:
            subprocess.run(["git", "-C", str(vlc), "-c", "core.hooksPath=/dev/null",
                            "apply", "--whitespace=nowarn", str(patch)], check=True, env=git_env)
        catalog = contrib_catalog(vlc)
        hashes = tree_hashes(stage)
        canonical_hashes = (json.dumps(hashes, ensure_ascii=False, indent=2, sort_keys=True) + "\n").encode()
        if hashlib.sha256(canonical_hashes).hexdigest() != LOCK["preparedTreeManifestSHA256"]:
            raise ValueError("Patched source tree differs from the reviewed pinned tree")
        stage.rename(prepared)
    write_json(output / "contrib-catalog.json", catalog)
    write_json(output / "prepared-hashes.json", hashes)
    report = {"schemaVersion": 1, "release": LOCK["release"], "completeCorrespondingSource": False,
              "sourceLockSHA256": digest(LOCK_PATH), "patchCount": len(patches),
              "sourceFileCount": len(hashes), "contribChecksumCandidates": len(catalog["archives"]),
              "releaseBlockers": LOCK["releaseBlockers"]}
    write_json(output / "source-review.json", report)
    print("PREPARED", len(patches), "upstream patches;", len(hashes), "source entries; release remains INCOMPLETE")


def verify(output):
    source_archives(output)
    checked(PROJECT / "Vendor" / LOCK["binary"]["filename"], LOCK["binary"]["sha256"])
    checked(PROJECT / LOCK["binary"]["frameworkPath"], LOCK["binary"]["frameworkSHA256"])
    checked(output / "prepared-hashes.json", LOCK["preparedTreeManifestSHA256"])
    if tree_hashes(output / "prepared") != json.loads((output / "prepared-hashes.json").read_text()):
        raise ValueError("Prepared source tree changed")
    report = json.loads((output / "source-review.json").read_text())
    if report["sourceLockSHA256"] != digest(LOCK_PATH) or report["completeCorrespondingSource"] is not False:
        raise ValueError("Review metadata does not match the pinned incomplete-source status")
    expected_catalog = contrib_catalog(output / "prepared/vlc")
    if expected_catalog != json.loads((output / "contrib-catalog.json").read_text()):
        raise ValueError("Contrib catalog does not match verified source")
    found = 0
    for item in expected_catalog["archives"]:
        path = output / "contrib-archives" / item["filename"]
        if path.exists() or path.is_symlink():
            checked(path, item["checksum"], item["algorithm"])
            found += 1
    # Preserve the exact license already shipped by the official binary package.
    with tarfile.open(PROJECT / "Vendor" / LOCK["binary"]["filename"]) as binary:
        official = binary.extractfile("VLCKit - binary package/COPYING.txt").read()
    if official != (PROJECT / "Packaging/Licenses/VLCKit-LGPL-2.1.txt").read_bytes():
        raise ValueError("Packaged LGPL text differs from the official binary")
    print("VERIFIED pinned binary/source archives, patched tree and LGPL;", found,
          "contrib candidates downloaded; complete corresponding source remains INCOMPLETE")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=["fetch", "prepare", "verify", "contrib", "bundle", "release-check"])
    parser.add_argument("--output", type=Path, default=PROJECT / "build/vlc-source-kit-3.7.3")
    parser.add_argument("--cache", type=Path, help="Reuse already-downloaded pinned source archives")
    parser.add_argument("--package", action="append", default=[], help="Explicit contrib package from the prepared catalog")
    args = parser.parse_args()
    output = args.output.absolute()
    if output.is_symlink():
        raise ValueError("Output directory cannot be a symlink")
    output.mkdir(parents=True, exist_ok=True)
    if args.command == "fetch":
        for item in LOCK["sources"]:
            path = output / "archives" / item["filename"]
            cached = args.cache / item["filename"] if args.cache else None
            if path.is_symlink():
                raise ValueError("Archive destination cannot be a symlink: " + str(path))
            if cached and cached.exists() and not path.exists():
                checked(cached, item["sha256"])
                path.parent.mkdir(parents=True, exist_ok=True)
                with tempfile.NamedTemporaryFile(dir=path.parent, delete=False) as target:
                    temporary = Path(target.name)
                try:
                    shutil.copyfile(cached, temporary)
                    checked(temporary, item["sha256"])
                    temporary.replace(path)
                finally:
                    temporary.unlink(missing_ok=True)
            download(item["url"], path, item["sha256"])
    elif args.command == "prepare":
        prepare(output)
    elif args.command == "contrib":
        verify(output)
        entries = contrib_catalog(output / "prepared/vlc")["archives"]
        available = {item["package"] for item in entries}
        if not args.package or not set(args.package) <= available:
            raise ValueError("Specify known --package values from contrib-catalog.json")
        for item in entries:
            if item["package"] in args.package:
                download(item["url"], output / "contrib-archives" / item["filename"], item["checksum"], item["algorithm"])
    else:
        verify(output)
        if args.command == "bundle":
            target = output / "VLCKit-3.7.3-source-review-INCOMPLETE.tar.gz"
            with tempfile.NamedTemporaryFile(dir=output, delete=False) as stream:
                temporary = Path(stream.name)
            try:
                with tarfile.open(temporary, "w:gz") as archive:
                    for name in ["prepared", "prepared-hashes.json", "contrib-catalog.json", "source-review.json", "contrib-archives"]:
                        path = output / name
                        if path.exists():
                            archive.add(path, arcname=name, filter=lambda member: None if ".git" in PurePosixPath(member.name).parts else member)
                    for name in ["Packaging/VLC/source-lock.json", "Packaging/Licenses/VLCKit-LGPL-2.1.txt",
                                 "Packaging/VLC_DISTRIBUTION.md", "Packaging/THIRD_PARTY_NOTICES.md", "LICENSE",
                                 "scripts/vlc-source-kit.py", "scripts/vlc-source-kit.sh"]:
                        archive.add(PROJECT / name, arcname=name)
                temporary.replace(target)
            finally:
                temporary.unlink(missing_ok=True)
            print("REVIEW_BUNDLE", target, digest(target), "INCOMPLETE; not ready for binary publication")
        elif args.command == "release-check":
            for blocker in LOCK["releaseBlockers"]:
                print("BLOCKED", blocker)
            return 2
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (OSError, ValueError, KeyError, tarfile.TarError, subprocess.CalledProcessError) as error:
        print("ERROR", str(error), file=sys.stderr)
        sys.exit(1)
