#!/usr/bin/python3 -I
"""Verify a patched XCFramework; --apply stages it, verifies again, then backs up and replaces."""
import argparse
import datetime
import importlib.util
import json
import os
from pathlib import Path
import shutil
import tempfile
import uuid

HERE = Path(__file__).resolve().parent
PROJECT = HERE.parent
spec = importlib.util.spec_from_file_location('patched_verifier', HERE / 'verify-patched-vlc.py')
verifier = importlib.util.module_from_spec(spec)
spec.loader.exec_module(verifier)

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', type=Path, required=True)
    parser.add_argument('--destination', type=Path, default=PROJECT / 'Vendor/VLCKit.xcframework')
    parser.add_argument('--lock', type=Path, default=PROJECT / 'Packaging/VLC/patched-lock.json')
    parser.add_argument('--apply', action='store_true')
    args = parser.parse_args()
    if args.source.is_symlink() or args.destination.is_symlink():
        raise RuntimeError('Source and destination must not be directory symlinks')
    source = args.source.resolve()
    destination = args.destination.resolve()
    if destination.name != 'VLCKit.xcframework' or destination.is_relative_to(source) or source.is_relative_to(destination):
        raise RuntimeError('Expected a separate VLCKit.xcframework destination')
    if destination.exists() and not destination.is_dir():
        raise RuntimeError('Existing destination must be a directory')
    lock = json.loads(args.lock.read_text())
    verifier.verify(source, lock)
    if not args.apply:
        print(json.dumps({'status':'VERIFIED_PLAN','destination':str(destination),'installationPerformed':False}, indent=2))
        return
    destination.parent.mkdir(parents=True, exist_ok=True)
    backup = None
    with tempfile.TemporaryDirectory(prefix='.vlc-import-', dir=destination.parent) as temporary:
        stage = Path(temporary) / 'VLCKit.xcframework'
        shutil.copytree(source, stage, symlinks=True)
        verifier.verify(stage, lock)
        if destination.exists():
            stamp = datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%dT%H%M%SZ')
            backup = destination.with_name(destination.name + '.backup-' + stamp + '-' + uuid.uuid4().hex)
            os.rename(destination, backup)
        try:
            os.rename(stage, destination)
        except BaseException:
            if backup is not None and not destination.exists():
                os.rename(backup, destination)
            raise
    print(json.dumps({'status':'IMPORTED','destination':str(destination),'backup':str(backup) if backup else None,
                      'installationPerformed':True,'sourceAndStageVerified':True}, indent=2))

if __name__ == '__main__':
    main()
