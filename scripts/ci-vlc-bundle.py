#!/usr/bin/env python3
"""Prepare the reviewed local VLC bundle for CI, or verify its source inputs."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import tarfile

ROOT = Path(__file__).resolve().parent.parent
LOCK = ROOT / 'Packaging/VLC/patched-lock.json'


def digest(path):
    value = hashlib.sha256()
    with path.open('rb') as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b''):
            value.update(block)
    return value.hexdigest()


def verify(materials):
    lock = json.loads(LOCK.read_text())
    for name, key in [('SourceMaterials.tar', 'sourceMaterialSHA256'),
                      ('SourceMaterialManifest.json', 'sourceManifestSHA256')]:
        if digest(materials / name) != lock[key]:
            raise RuntimeError('VLC source identity mismatch: ' + name)
    supplementary = json.loads((ROOT / 'Packaging/VLC/ci-materials-lock.json').read_text())
    for name, expected in supplementary['files'].items():
        path = materials / name
        if not path.is_file() or digest(path) != expected:
            raise RuntimeError('Missing or modified VLC supplemental material: ' + name)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('command', choices=['create', 'verify'])
    parser.add_argument('materials', type=Path, nargs='?', default=ROOT / 'build/vlc-source-delivery')
    args = parser.parse_args()
    verify(args.materials)
    if args.command == 'verify':
        print('VLC source archive and manifest match the committed lock.')
        return
    framework = ROOT / 'Vendor/VLCKit.xcframework'
    subprocess.run(['/usr/bin/python3', '-I', str(ROOT / 'scripts/verify-patched-vlc.py'),
                    '--package', str(framework), '--lock', str(LOCK)], check=True)
    output = ROOT / 'build/ci-inputs/Audilse-vlc-dependencies.tar.gz'
    output.parent.mkdir(parents=True, exist_ok=True)
    if output.exists():
        raise RuntimeError('Bundle already exists; move it aside before creating another: ' + str(output))
    try:
        with tarfile.open(output, 'w:gz', compresslevel=3) as archive:
            archive.add(framework, arcname='VLCKit.xcframework')
            archive.add(args.materials, arcname='vlc-source-delivery')
    except BaseException:
        output.unlink(missing_ok=True)
        raise
    checksum = digest(output)
    output.with_suffix(output.suffix + '.sha256').write_text(checksum + '  ' + output.name + '\n')
    print(str(output))
    print('VLC_BUNDLE_SHA256=' + checksum)


if __name__ == '__main__':
    main()
