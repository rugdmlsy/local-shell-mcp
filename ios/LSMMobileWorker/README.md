# LSM Mobile Worker for iOS

A native iPhone/iPad companion for local-shell-mcp. It joins the existing remote-worker registry and poll protocol, but advertises only capabilities that iOS can provide. It is intentionally not a POSIX shell worker.

## Capabilities

The app advertises `mobile` plus capability-specific identifiers and receives bounded jobs through the `mobile_action` MCP tool.

### Core

- `capabilities`: current native capabilities and permission state.
- `device_info`: model, iOS version, CPU/memory summary, app state.
- `battery`: battery level/state and Low Power Mode.
- `notify`: post a local notification after permission was granted in the app.
- `location`: one-shot location after permission was granted in the app.
- `open_url`: open an HTTP/HTTPS URL while the app is active.
- `list_files`, `read_text`, `write_text`, `delete_file`: sandboxed access under `Documents/LSM`.

### Camera and Photos

- `camera_capture`: capture one still image while the app is in the foreground. The result is saved under `Documents/LSM/Captures` and returns path, dimensions, byte size, and SHA-256.
- `photos_list`: list a bounded set of accessible Photo Library assets.
- `photos_export`: export one accessible photo into `Documents/LSM/Photos` for later transfer or inspection.

Camera and Photo Library permission prompts are only initiated by explicit buttons in the app. A remote job never triggers a new privacy prompt.

### Mobile network vantage point

- `network_status`: report the current `NWPath` state, active interface class (Wi-Fi/cellular/etc.), expensive/constrained status, IPv4/IPv6 and DNS support.
- `http_probe`: bounded HTTP/HTTPS GET or HEAD from the phone, with a 1-20 second timeout and a maximum 64 KiB response sample.

`http_probe` rejects localhost, `.local`, private, loopback, and link-local targets by default. This keeps ordinary remote jobs from implicitly crossing the iOS Local Network privacy boundary.

### Binary and image transfer

The mobile app does not put large media payloads into `mobile_action` JSON. It implements the existing LSM transfer wire tools used by `remote_transfer` and `image_view`:

- `transfer_stat`
- `transfer_upload_url`
- `transfer_download_url`

Transfers are constrained to `Documents/LSM`, use raw HTTP transfer tickets, enforce a 4 MiB chunk limit, and verify expected byte size and SHA-256.

Examples after the worker is online:

```text
remote_transfer(
  source_machine="morrow-iphone",
  source_path="Captures/photo.jpg",
  destination_path="/tmp/iphone-photo.jpg"
)

image_view(machine="morrow-iphone", path="Captures/photo.jpg")
```

## App Intents / Shortcuts

The app contributes three Shortcuts/Siri actions:

- **Check In LSM Worker**: run one bounded controller check-in and process immediately available work.
- **LSM Worker Status**: report whether the device is paired and its most recent worker state.
- **Open LSM Worker**: foreground the app.

The intents reuse the same Keychain identity and job runtime as foreground polling; they do not expose or duplicate the bearer token.

## Background availability

An iOS app is not a permanent daemon. The worker therefore uses several best-effort paths:

1. Foreground long polling while the app is active.
2. Automatic reconnect whenever the app becomes active.
3. `BGAppRefresh` to request occasional bounded background check-ins when iOS grants runtime.
4. Optional APNs silent push to request a bounded check-in when a push-capable Apple Developer team is available.

None of these provide Linux/macOS-style 24/7 process semantics. The controller must continue to treat the phone as an intermittently available endpoint.

## APNs configuration

The controller has optional APNs HTTP/2 provider support. Configure all of the following before enabling it:

```text
LOCAL_SHELL_MCP_REMOTE_MOBILE_APNS_ENABLED=true
LOCAL_SHELL_MCP_REMOTE_MOBILE_APNS_TEAM_ID=...
LOCAL_SHELL_MCP_REMOTE_MOBILE_APNS_KEY_ID=...
LOCAL_SHELL_MCP_REMOTE_MOBILE_APNS_KEY_PATH=/path/to/AuthKey_....p8
LOCAL_SHELL_MCP_REMOTE_MOBILE_APNS_TOPIC=com.xycdev.lsmmobileworker
```

The provider key must remain outside the repository. APNs settings are redacted from diagnostics.

The current development account used for this app is a Personal Team. Apple does not permit Personal Teams to provision the Push Notifications entitlement. To keep ordinary development/install working, the Xcode project therefore has separate configurations:

- `Debug` / `Release`: no `aps-environment`; works with the current Personal Team. BGAppRefresh and all foreground/native capabilities remain available.
- `PushDebug`: compiles APNs registration and applies `Sources/LSMMobileWorker.entitlements`. Use this only after selecting a paid/push-capable Apple Developer team.

The controller preserves its old offline behavior when APNs is absent: it does not queue work indefinitely for a sleeping phone.

## Pairing

1. Create a remote-worker invite for the phone, for example `morrow-iphone`.
2. Enter the controller URL, invite code, and worker name in the app.
3. Tap **Pair & Connect**. The controller-issued token is stored in Keychain.
4. Later launches call `/remote/resume` automatically.

The current deployment uses `https://mcp.xycdev.com` as the phone-reachable controller URL.

## Security and privacy model

- Worker credentials live in the iOS Keychain, not `UserDefaults`.
- Native workers send `supports_self_update=false`; the controller never attempts to replace the app with the Python worker bundle.
- Files are constrained to `Documents/LSM`; absolute paths and traversal are rejected.
- Camera, Photos, Notifications, and Location require explicit local permission first.
- Camera capture also requires the app to be foregrounded.
- `open_url` accepts only HTTP/HTTPS.
- Network probes are bounded and avoid private/local destinations by default.
- The app advertises no shell, Python, Playwright, package, service-management, or restart capability.
- APNs device tokens are persisted by the controller but are not returned from `remote_manage(list)`.

## Build

Generate the Xcode project:

```sh
xcodegen generate --spec ios/LSMMobileWorker/project.yml --project ios/LSMMobileWorker
```

Compile without signing:

```sh
xcodebuild \
  -project ios/LSMMobileWorker/LSMMobileWorker.xcodeproj \
  -scheme LSMMobileWorker \
  -configuration Debug \
  -sdk iphoneos \
  CODE_SIGNING_ALLOWED=NO \
  build
```

For the APNs-ready compile path, replace `Debug` with `PushDebug`. A signed `PushDebug` build additionally requires a provisioning team that supports Push Notifications.

For a physical iPhone, select an Apple Development team, enable Developer Mode, pair/trust the Mac, then build/install the normal `Debug` configuration. The current Phase 2 app version is `0.2.1`.
