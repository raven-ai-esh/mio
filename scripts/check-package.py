#!/usr/bin/env python3
"""Verify actual ZIP and mounted DMG content without launching the app."""
import hashlib
import json
import plistlib
import subprocess
import tempfile
from pathlib import Path

root = Path(__file__).resolve().parents[1]

def manifest(app):
    subprocess.run(['codesign', '--verify', '--deep', '--strict', str(app)], check=True)
    return {str(p.relative_to(app)): hashlib.sha256(p.read_bytes()).hexdigest()
            for p in app.rglob('*') if p.is_file()}

with tempfile.TemporaryDirectory(prefix='mio-package-check-') as directory:
    base = Path(directory)
    expanded = base / 'zip'
    subprocess.run(['ditto', '-x', '-k', str(root / 'dist/Mio-macOS.zip'), str(expanded)], check=True)
    expected = manifest(expanded / 'Mio.app')
    receipt = {'executable_sha256': expected['Contents/MacOS/Mio'], 'checks': ['zip_signature_verified']}
    mount = base / 'mounted'
    mount.mkdir()
    result = subprocess.check_output(['hdiutil', 'attach', '-readonly', '-nobrowse', '-plist',
                                     '-mountpoint', str(mount), str(root / 'dist/Mio-macOS.dmg')])
    info = plistlib.loads(result)
    try:
        assert any(Path(x.get('mount-point', '/')).resolve() == mount.resolve()
                   for x in info['system-entities'])
        assert manifest(mount / 'Mio.app') == expected, 'DMG payload differs from signed bundle'
        assert (mount / 'Applications').is_symlink()
        assert (mount / 'Applications').readlink() == Path('/Applications')
        receipt['checks'].append('mounted_dmg_signature_every_file_hash_and_install_link_match')
    finally:
        subprocess.run(['hdiutil', 'detach', str(mount)], check=True, stdout=subprocess.DEVNULL)
receipt['status'] = 'PASS'
destination = root / 'artifacts/ui/package-receipt.json'
destination.parent.mkdir(parents=True, exist_ok=True)
destination.write_text(json.dumps(receipt, indent=2) + '\n')
print(json.dumps(receipt, indent=2))
