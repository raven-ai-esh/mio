# Building and testing Mio

## Requirements

- Apple Silicon Mac, macOS 15 or newer.
- Full Xcode with its command-line tools selected; Swift 6.2 or newer. The current development build has been tested with Xcode 26.3 / Swift 6.2.4.
- Python 3 for packaging and synthetic acceptance scripts.
- Network access for the pinned Swift dependencies. The semantic model is a separate optional in-app download.

## Build

```sh
python3 scripts/build-app.py --dmg
python3 scripts/check-package.py
```

The packager builds the embedding worker and Mio executable, bundles its Metal library, localization resources, model manifest, icon and third-party notices, and signs the generated bundle ad hoc. It assembles outside an iCloud-managed checkout to avoid file-provider extended attributes interfering with signing.

Outputs are dist/Mio-macOS.zip and dist/Mio-macOS.dmg. The package checker verifies the ZIP and mounted DMG signatures and compares all payload hashes.

## Install locally

```sh
python3 scripts/install-local.py
open /Applications/Mio.app
```

The installer verifies the source package, archives the existing app as a ZIP, checks that the archive restores identical bytes, replaces the app and verifies the installed payload. User memory is stored separately from the application bundle.

Developer builds are ad hoc signed and not notarized. Installing a public binary with Developer ID/notarization is a separate distribution step; this repository currently provides the local build path.

## Verify

```sh
swift test
python3 scripts/check-space-catalog.py \
  --executable /Applications/Mio.app/Contents/MacOS/Mio \
  --receipt artifacts/catalog-check.json
python3 scripts/check-note-management.py \
  --executable /Applications/Mio.app/Contents/MacOS/Mio \
  --receipt artifacts/note-management-check.json
```

The automated suite uses synthetic data. A real iCloud file-provider test requires explicitly supplied isolated cloud/artifact directories and is skipped when they are unavailable. Unit tests do not substitute for native UI or real MCP/persistence verification.

The catalog and note-management scripts each create a fresh temporary store, run a real owner process and stdio MCP client, and check the persisted downstream state. The management script also exercises moves, metadata, history, original files, deletion/restoration and owner restart. It does not access your existing memory.

## Reproduce the demo

Use a new empty directory:

```sh
python3 scripts/make-demo.py \
  --executable /Applications/Mio.app/Contents/MacOS/Mio \
  --data-directory /tmp/mio-aurora-demo \
  --receipt artifacts/aurora-demo.json
```

The script refuses a non-empty directory. It creates fictional Aurora notes, a two-page PDF, links, a scoped profile and a recorded MCP session. The profile credential remains in the local test store and is not included in the receipt.
