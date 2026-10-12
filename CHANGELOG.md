# Changelog

## iPhone source update — IPA import and TrollStore handoff
- Added visible **Import IPA** and **Refresh** controls to the Downloads tab.
- Added multi-select IPA import from the iOS Files picker; imported files are copied into the Store's own Downloads folder.
- Downloads remain visible in Files under **On My iPhone → Legacy iOS Store → Downloads** (document sharing is enabled in the Xcode target).
- Added a direct TrollStore URL-scheme action to archive entries, using the official `apple-magnifier://install?url=...` handoff for remote IPA URLs.
- Added a local-file share/open action so downloaded/imported IPAs can be passed to compatible apps, including TrollStore Lite when iOS offers it as a destination.
- Kept the Legacy Store signing/install action visible but clearly marked its backend as not implemented; AppSync Unified is not itself an IPA signing engine.
- Kept delete, refresh, and newest-first download listing.

## Known limitations
- This is an Xcode source project, not a compiled/signed IPA. A full build and device test require Xcode on macOS.
- Direct TrollStore URL handoff depends on TrollStore Lite being installed and registering the `apple-magnifier` URL scheme. If it does not open, download the IPA and use **Open / Share IPA** or Files to hand it off manually.
- The Store's own on-device fake-signing/privileged installation backend is not implemented yet. This UI does not claim otherwise.
- Online catalog search is currently a search view, not the full desktop details/version workflow. Download progress and icons also remain limited compared with the Windows app.

## Build automation update
- Added a shared Xcode scheme so the project can be built consistently by command-line Xcode.
- Added a GitHub Actions macOS workflow to build the iOS target from a Windows-only development setup and upload an unsigned IPA package, app bundle ZIP, and build log.
- Documented private-repository setup and the limits of unsigned IPA packaging.
