# LSM Mobile Worker for iOS

A native iOS companion for local-shell-mcp. It joins the existing remote-worker registry and poll protocol, but advertises only iOS capabilities it can actually provide. It is not a POSIX shell worker.

## MVP capabilities

The app advertises `mobile` plus capability-specific identifiers and executes controller jobs sent through the `mobile_action` MCP tool.

Supported actions:

- `capabilities`: report the native capability set and permission state.
- `device_info`: device model/name, iOS version, locale, memory, and app state.
- `battery`: battery level/state and Low Power Mode.
- `notify`: schedule a local notification after the user has granted notification permission in the app.
- `location`: return a one-shot location after the user has granted location permission in the app.
- `open_url`: open an HTTP/HTTPS URL while the app is active.
- `list_files`: list files under the app-managed `Documents/LSM` root.
- `read_text`: read UTF-8 text under `Documents/LSM`, capped at 512 KiB.
- `write_text`: write UTF-8 text under `Documents/LSM`, capped at 5 MiB.
- `delete_file`: delete a file or directory under `Documents/LSM`.

## Security model

- The controller-issued worker token is stored in the iOS Keychain, not `UserDefaults`.
- Native workers send `supports_self_update=false`; the controller does not try to replace the iOS app with the Python worker bundle.
- File operations are constrained to `Documents/LSM`; absolute paths and path traversal are rejected.
- Remote commands never trigger notification or location permission prompts. The user grants those permissions explicitly in the app first.
- `open_url` accepts only HTTP/HTTPS URLs.
- The app advertises no shell, Python, Playwright, service-management, or restart capability.

## Pairing

1. On the controller, create an invite for the phone, for example `morrow-iphone`.
2. In the iOS app, enter the controller URL, invite code, and desired worker name.
3. Tap Connect. The app registers once and stores the returned identity in Keychain.
4. Later launches use `/remote/resume` automatically.

The controller URL must be reachable from the phone. For the current deployment, the public HTTPS controller URL is appropriate.

## Build

The Xcode project is generated from `project.yml` using XcodeGen:

```sh
xcodegen generate --spec ios/LSMMobileWorker/project.yml --project ios/LSMMobileWorker
```

Then build with the full Xcode toolchain:

```sh
xcodebuild \
  -project ios/LSMMobileWorker/LSMMobileWorker.xcodeproj \
  -scheme LSMMobileWorker \
  -sdk iphonesimulator \
  -configuration Debug \
  CODE_SIGNING_ALLOWED=NO \
  build
```

For a physical iPhone, select an Apple Development team in Xcode or pass the appropriate signing settings, enable Developer Mode on the phone, trust/pair the Mac, and build to that device.

## iOS availability semantics

This worker is intentionally modeled as an intermittently available mobile endpoint. iOS does not permit a third-party app to run an arbitrary permanent daemon. Long polling works while the app is active and may receive a limited amount of background execution time, but the controller must treat an inactive/suspended phone as offline rather than assuming desktop-worker availability.

A later phase can add APNs/background-task wakeups for eligible work, but that still will not provide desktop-style 24/7 process semantics.

## Planned follow-ups

- camera capture and photo-library transfer with explicit user permission;
- network-probe actions useful from a mobile/cellular vantage point;
- App Intents / Shortcuts integration;
- clipboard write/share-sheet integration;
- APNs-assisted wakeup for bounded jobs;
- richer permission/capability reporting in the LSM Machines UI.
