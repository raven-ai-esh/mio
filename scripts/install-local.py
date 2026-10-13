#!/usr/bin/env python3
"""Install the verified ZIP; older versions remain recoverable ZIP archives."""
from pathlib import Path
import argparse
import hashlib
import json
import os
import plistlib
import shutil
import subprocess
import tempfile
import time

root = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--target', type=Path, default=Path('/Applications/Mio.app'))
parser.add_argument('--backup-directory', type=Path,
                    default=Path.home() / 'Library/Application Support/app.mio.memory/ApplicationBackups')
args = parser.parse_args()
target = args.target.absolute()
archive = root / 'dist/Mio-macOS.zip'
if not archive.is_file():
    raise SystemExit('Build dist/Mio-macOS.zip first')

def verify(app):
    info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
    if info.get('CFBundleIdentifier') != 'app.mio.memory':
        raise SystemExit('Refusing to replace or install an unrelated application')
    subprocess.run(['codesign', '--verify', '--deep', '--strict', str(app)], check=True)
    manifest = {}
    for path in app.rglob('*'):
        key = str(path.relative_to(app))
        if path.is_symlink():
            manifest[key] = 'symlink:' + os.readlink(path)
        elif path.is_file():
            manifest[key] = hashlib.sha256(path.read_bytes()).hexdigest()
        elif path.is_dir():
            manifest[key] = 'directory'
    return manifest

if target.is_symlink():
    raise SystemExit('Refusing to replace an Applications symlink')
backup = None
with tempfile.TemporaryDirectory(prefix='mio-install-') as directory:
    base = Path(directory)
    subprocess.run(['ditto', '-x', '-k', str(archive), str(base)], check=True)
    source = base / 'Mio.app'
    expected = verify(source)
    previous = base / 'previous.app'
    if target.exists():
        prior = verify(target)
        args.backup_directory.mkdir(parents=True, exist_ok=True)
        backup = args.backup_directory / ('Mio-' + str(time.time_ns()) + '.zip')
        subprocess.run(['ditto', '-c', '-k', '--sequesterRsrc', '--keepParent', str(target), str(backup)], check=True)
        restored = base / 'backup-check'
        subprocess.run(['ditto', '-x', '-k', str(backup), str(restored)], check=True)
        if verify(restored / target.name) != prior:
            raise SystemExit('Backup bytes differ; original application retained')
        target.rename(previous)
    try:
        subprocess.run(['ditto', '--noqtn', str(source), str(target)], check=True)
        if verify(target) != expected:
            raise RuntimeError('Installed bundle bytes differ from the verified ZIP')
    except BaseException:
        if target.exists() and not target.is_symlink():
            shutil.rmtree(target)
        if previous.exists():
            previous.rename(target)
        raise
receipt = {'path': str(target), 'executable_sha256': expected['Contents/MacOS/Mio'],
           'signature_verified': True, 'earlier_app_backup': str(backup) if backup else None,
           'backup_format': 'zip', 'distribution': str(archive)}
if target == Path('/Applications/Mio.app'):
    ls = '/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister'
    subprocess.run([ls, '-f', str(target)], check=True)
    receipt_path = root / 'artifacts/ui/install-receipt.json'
    receipt_path.parent.mkdir(parents=True, exist_ok=True)
    receipt_path.write_text(json.dumps(receipt, indent=2) + '\n')
print(json.dumps(receipt, indent=2))
