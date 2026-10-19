#!/usr/bin/python3 -I
"""Read-only verification of the reviewed patched XCFramework, before local signing."""
import argparse
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import plistlib
import subprocess
import stat
import tempfile

def digest(path):
    value = hashlib.sha256()
    with path.open('rb') as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b''):
            value.update(block)
    return value.hexdigest()

def verify(package, lock):
    if lock['schemaVersion'] != 1 or lock['identity'] != 'shelf-vlc-copy-drain-input1':
        raise RuntimeError('Unsupported patched lock')
    if not package.is_dir() or package.is_symlink():
        raise RuntimeError('Expected a real XCFramework directory')
    expected = lock['packageFiles']
    members = list(package.rglob('*'))
    if any(not (p.is_file() or p.is_dir() or p.is_symlink()) for p in members):
        raise RuntimeError('Unsupported special package entry')
    actual = {str(p.relative_to(package)): p for p in members if p.is_file() or p.is_symlink()}
    if set(actual) != set(expected):
        raise RuntimeError('Package membership mismatch; missing or unexpected files')
    for name, row in expected.items():
        relative = PurePosixPath(name)
        if relative.is_absolute() or '..' in relative.parts or str(relative) != name:
            raise RuntimeError('Unsafe lock path')
        path = actual[name]
        if not path.resolve().is_relative_to(package):
            raise RuntimeError('Package link escapes root: ' + name)
        if 'symlink' in row:
            if not path.is_symlink() or os.readlink(path) != row['symlink']:
                raise RuntimeError('Package symlink mismatch: ' + name)
        elif path.is_symlink() or path.stat().st_size != row['bytes'] or stat.S_IMODE(path.stat().st_mode) != row['mode'] or digest(path) != row['sha256']:
            raise RuntimeError('Package bytes mismatch: ' + name)
    info = plistlib.loads((package / 'Info.plist').read_bytes())
    libraries = info['AvailableLibraries']
    if len(libraries) != 1 or libraries[0]['SupportedPlatform'] != 'macos' or set(libraries[0]['SupportedArchitectures']) != {'arm64', 'x86_64'}:
        raise RuntimeError('Expected one universal macOS variant')
    binary = package / lock['binaryPath']
    if digest(binary) != lock['binarySHA256']:
        raise RuntimeError('Patched binary mismatch')
    with tempfile.TemporaryDirectory(prefix='shelf-vlc-verify-') as temporary:
        for arch, expected_hash in lock['sliceSHA256'].items():
            thin = Path(temporary) / arch
            subprocess.run(['/usr/bin/lipo', str(binary), '-thin', arch, '-output', str(thin)], check=True, capture_output=True)
            if digest(thin) != expected_hash:
                raise RuntimeError('Patched slice mismatch: ' + arch)
    return {'status': 'PASS', 'files': len(actual), 'binarySHA256': lock['binarySHA256'],
            'runtimeExecutionPerformed': False, 'installationPerformed': False,
            'scope': 'Exact unsigned candidate package; runtime bridge must separately enforce the locked changeset'}

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--package', type=Path, required=True)
    parser.add_argument('--lock', type=Path, required=True)
    args = parser.parse_args()
    # Preserve the symlink check before canonicalizing the package directory.
    if args.package.is_symlink():
        raise RuntimeError('Package directory must not be a symlink')
    result = verify(args.package.resolve(), json.loads(args.lock.read_text()))
    print(json.dumps(result, indent=2))

if __name__ == '__main__':
    main()
