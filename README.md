# Legacy iOS Store — native iPhone source (iOS 16.0+)

A native SwiftUI starter based on the user's `LegacyiOSStore_v2.6.6.zip`. It includes the bundled Internet Archive IPA index and targets iOS 16.0+, including iOS 16.7.16.

## Current features
- Native iPhone/iPad interface with Archive IPAs, Online Store, and Downloads tabs.
- Search the bundled Internet Archive IPA index offline.
- Search the online Legacy Store API (`https://legacystore.app/api/v1/apps`).
- Download archive IPAs into the app's `Documents/Downloads` folder.
- Browse newest-first local IPA downloads, delete them, and refresh the list.
- Import one or more `.ipa` files from the iOS Files picker into the Store's Downloads folder.
- Access the app's Documents folder through Files at **On My iPhone → Legacy iOS Store → Downloads**.
- Hand an archive IPA to TrollStore through its documented `apple-magnifier://install?url=...` URL scheme, when registered on the device.
- Share/open a local IPA with compatible apps; choose TrollStore Lite if it appears in the iOS share/open sheet.
- Basic status and error reporting.

## Important limitations
- This is **source code, not a compiled/signed IPA**. Building and exporting an installable app requires Xcode on macOS and a suitable signing/install method.
- The Store's own on-device fake-signing and privileged installation backend is **not implemented yet**. The “Legacy Store Sign / Install” action explains this instead of claiming success. AppSync Unified may permit compatible unsigned/fake-signed apps to install on a suitable jailbroken setup, but it does not sign an IPA by itself.
- TrollStore handoff depends on TrollStore Lite being installed and registering the `apple-magnifier` URL scheme. For a local IPA, the app opens the iOS share/open sheet; choose TrollStore Lite if it is offered. If either route fails, use Files/Filza to open the IPA with the installer manually.
- Direct URL handoff is only offered for archive entries with a valid URL. It asks TrollStore to fetch the IPA from that remote URL; it does not first download the file into this app.
- Online search is not yet the full desktop app detail/version workflow. Byte-by-byte progress and archive icons are also not implemented yet.

## Rootless / rootful clue
In Filza, `/var/jb` existing and containing jailbreak folders strongly suggests a rootless setup, but is not absolute proof if the environment was modified.

## Build
1. Open `LegacyiOSStoreiPhone.xcodeproj` in Xcode on a Mac.
2. Select the `LegacyiOSStoreiPhone` target and choose a signing team under Signing & Capabilities.
3. Connect the iPhone running iOS 16.7.16, select it as the run destination, and Build/Run.
4. For a distributable IPA, archive/export with an appropriate signing method. An ordinary Apple development-signed build cannot install arbitrary downloaded IPAs itself.

## Build from Windows with GitHub Actions

This repository includes `.github/workflows/build-ios.yml`. After the project files are uploaded to a GitHub repository, the workflow runs on a hosted macOS runner and creates build artifacts without requiring a Mac or a local macOS VM.

1. Create a **private** GitHub repository.
2. Extract this ZIP on Windows and upload the *contents* of the `LegacyiOSStore_iPhone` folder (including `.github`) to the repository root. Make sure the workflow file is at `.github/workflows/build-ios.yml`.
3. In GitHub, open **Actions → Build Legacy iOS Store (iPhone) → Run workflow** (a push to `main` also starts it).
4. Open the completed run and download the `LegacyiOSStore-iPhone-build` artifact.

The workflow produces an unsigned IPA package and an app ZIP for inspection. This is a **build artifact, not a promise of an install-ready IPA**: unsigned device apps require a compatible signing/install method. Test using TrollStore Lite or your jailbreak setup only after verifying the workflow completed successfully. The workflow does not upload private signing keys or use an Apple Developer account.

If the build fails, open the failed Actions run and download the build log from the artifact if it was produced; share the first compiler error here so it can be fixed.
