#!/usr/bin/env python3
"""Build a self-contained, locally signed macOS app from this checkout."""
from pathlib import Path
import argparse
import os
import plistlib
import shutil
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser()
parser.add_argument('--debug', action='store_true')
parser.add_argument('--dmg', action='store_true')
args = parser.parse_args()
configuration = 'debug' if args.debug else 'release'
runtime_build = Path.home() / 'Library/Caches/app.mio.memory/embedding-runtime-build'
subprocess.run(['xcodebuild', '-scheme', 'MioEmbedWorker', '-configuration', 'Release',
                '-destination', 'platform=macOS,arch=arm64', '-derivedDataPath', str(runtime_build),
                '-disableAutomaticPackageResolution', 'build'], cwd=root / 'Vendor/EmbeddingGemma2Swift', check=True)
native_products = runtime_build / 'Build/Products/Release'
subprocess.run(['swift', 'build', '-c', configuration], cwd=root, check=True)
bin_dir = Path(subprocess.check_output(['swift', 'build', '-c', configuration, '--show-bin-path'], cwd=root, text=True).strip())
dist = root / 'dist'
dist.mkdir(exist_ok=True)
# Assemble/sign outside iCloud-managed Documents. The provider can immediately
# reattach FinderInfo to an app folder in Documents, even after xattr removal.
bundle_stage = tempfile.TemporaryDirectory(prefix='mio-package-')
app = Path(bundle_stage.name) / 'Mio.app'
contents = app / 'Contents'
macos = contents / 'MacOS'
resources = contents / 'Resources'
macos.mkdir(parents=True)
resources.mkdir()
shutil.copy2(bin_dir / 'Mio', macos / 'Mio')
os.chmod(macos / 'Mio', 0o755)
shutil.copy2(native_products / 'MioEmbedWorker', macos / 'MioEmbedWorker')
os.chmod(macos / 'MioEmbedWorker', 0o755)
# MLX first loads its Metal library next to the native executable. This
# path survives installation without the checkout or Xcode derived products.
shutil.copy2(native_products / 'mlx-swift_Cmlx.bundle/Contents/Resources/default.metallib', macos / 'mlx.metallib')
shutil.copy2(root / 'Sources/MioEmbeddings/ModelManifest.json', resources / 'ModelManifest.json')
shutil.copytree(bin_dir / 'Mio_Mio.bundle', resources / 'Mio_Mio.bundle')
licenses = resources / 'ThirdParty'
licenses.mkdir()
for filename in ['LICENSE', 'NOTICE', 'APACHE-2.0.txt', 'UPSTREAM_MLX_VLM_LICENSE', 'UPSTREAM_PILLOW_LICENSE', 'UPSTREAM.json', 'Package.resolved']:
    source = root / 'Vendor/EmbeddingGemma2Swift' / filename
    if source.exists():
        shutil.copy2(source, licenses / ('EmbeddingGemma2Swift-' + filename))
for dependency in (runtime_build / 'SourcePackages/checkouts').iterdir():
    for source in dependency.iterdir():
        if source.is_file() and (source.name.upper().startswith('LICENSE') or source.name.upper().startswith('NOTICE')):
            shutil.copy2(source, licenses / (dependency.name + '-' + source.name))
info = {
    'CFBundleName': 'Mio', 'CFBundleDisplayName': 'Mio',
    'CFBundleIdentifier': 'app.mio.memory', 'CFBundleExecutable': 'Mio',
    'CFBundlePackageType': 'APPL', 'CFBundleShortVersionString': '0.5.0',
    'CFBundleVersion': '12', 'LSMinimumSystemVersion': '15.0',
    'CFBundleDevelopmentRegion': 'en', 'CFBundleLocalizations': ['en', 'ru'],
    'NSHighResolutionCapable': True, 'NSPrincipalClass': 'NSApplication',
    'CFBundleIconFile': 'AppIcon',
    'UTExportedTypeDeclarations': [{'UTTypeIdentifier': 'app.mio.note-selection', 'UTTypeDescription': 'Mio note selection', 'UTTypeConformsTo': ['public.data']}],
}
with (contents / 'Info.plist').open('wb') as stream:
    plistlib.dump(info, stream)
iconset = dist / 'AppIcon.iconset'
iconset.mkdir(exist_ok=True)
subprocess.run(['swift', str(root / 'scripts/make-icon.swift'), str(iconset)], check=True)
subprocess.run(['iconutil', '-c', 'icns', str(iconset), '-o', str(resources / 'AppIcon.icns')], check=True)
shutil.copy2(root / 'Sources/CSQLite/PROVENANCE.md', resources / 'SQLite-Provenance.md')
# Finder/iCloud can attach FinderInfo to this newly created bundle. Codesign
# rejects FinderInfo/resource forks; remove only those attributes from our own
# generated bundle, preserving file-provider metadata and user files.
for path in [app, *app.rglob('*')]:
    for attribute in ('com.apple.FinderInfo', 'com.apple.ResourceFork'):
        subprocess.run(['/usr/bin/xattr', '-d', attribute, str(path)],
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
subprocess.run(['codesign', '--force', '--sign', '-', '--timestamp=none', str(macos / 'mlx.metallib')], check=True)
subprocess.run(['codesign', '--force', '--sign', '-', '--timestamp=none', str(macos / 'MioEmbedWorker')], check=True)
subprocess.run(['codesign', '--force', '--sign', '-', '--timestamp=none', str(app)], check=True)
subprocess.run(['codesign', '--verify', '--deep', '--strict', str(app)], check=True)
archive = dist / 'Mio-macOS.zip'
if archive.exists():
    archive.unlink()
subprocess.run(['ditto', '-c', '-k', '--sequesterRsrc', '--keepParent', str(app), str(archive)], check=True)
if args.dmg:
    stage = Path(bundle_stage.name) / 'dmg-stage'
    if stage.exists():
        shutil.rmtree(stage)
    stage.mkdir()
    # MetalLib signatures live in com.apple.cs.* extended attributes. Python
    # copytree on macOS loses them; ditto preserves signing metadata.
    subprocess.run(['ditto', '--noqtn', str(app), str(stage / 'Mio.app')], check=True)
    subprocess.run(['codesign', '--verify', '--deep', '--strict', str(stage / 'Mio.app')], check=True)
    (stage / 'Applications').symlink_to('/Applications')
    image = dist / 'Mio-macOS.dmg'
    if image.exists():
        image.unlink()
    subprocess.run(['hdiutil', 'create', '-volname', 'Mio', '-srcfolder', str(stage), '-ov', '-format', 'UDZO', str(image)], check=True)
# Persistent .app build copies/aliases are discovered as duplicate apps.
# Keep only the compressed distribution artifacts after the temporary stage.
print(archive)
