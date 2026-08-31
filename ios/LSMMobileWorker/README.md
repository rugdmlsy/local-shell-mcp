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
- `network_history`: return the last 32 meaningful path changes observed while the app process is alive.
- `dns_probe`: resolve a public hostname from the phone and report returned IPv4/IPv6 addresses and latency.
- `tcp_probe`: establish a bounded TCP connection to a public host/port from the phone.
- `tls_probe`: establish a bounded TLS connection to a public host/port while preserving hostname SNI.
- `http_probe`: bounded HTTP/HTTPS GET or HEAD from the phone, with a 1-20 second timeout and a maximum 64 KiB response sample.

Active probes reject localhost, `.local`, private, loopback, link-local, ULA, and CGNAT destinations. Hostnames are resolved first and rejected if they resolve to a local/private address before an active connection is attempted. This keeps ordinary remote jobs from implicitly crossing the iOS Local Network privacy boundary and avoids a simple DNS-rebinding bypass.

### Device status, sensors, and local code scanner

- `device_status`: storage capacity/availability, thermal state, uptime, display metrics, locale/timezone, battery and power state.
- `sensor_snapshot`: one bounded foreground sample of accelerometer, gyroscope, magnetometer, gravity, user acceleration, and device attitude when those sensors are available.
- `last_scanned_code`: return the most recent QR/barcode result captured locally in the app.

QR/barcode scanning is deliberately different from `camera_capture`: a remote caller cannot start the scanner. The user must tap **Scan QR / Barcode** in LSM Worker or invoke the scanner Shortcut, both of which foreground the app. The controller may only read the last saved scan result.

### Mobile inbox and controller dashboard

- `send_to_mobile`: deliver bounded text, an HTTP/HTTPS URL, or a file already present in `Documents/LSM` into the phone's local LSM Inbox.
- `inbox_list`: inspect the bounded local inbox.
- The app has read-only **Machines & active jobs**, **LSM Inbox**, and **Controller Events** screens.
- The dashboard uses the worker's existing bearer identity and returns sanitized status/job metadata; it does not expose shell commands, output, controller OAuth credentials, or other worker credentials.

`notify` and `send_to_mobile` support controller-side deferred delivery. When the iPhone is suspended/offline and `defer_if_offline=true`, the controller stores a bounded, TTL-limited event and hands it to the authenticated iOS poll channel when the app next wakes. Event IDs are acknowledged and durably deduplicated so reconnects do not replay the same notification indefinitely.

### Approval terminal

- `approval_prompt`: display a foreground-only native approval sheet with a bounded title, summary, details, and `low`/`medium`/`high`/`critical` risk level.
- The worker heartbeats while waiting, then returns `approved` or `rejected` to the caller.
- The phone does **not** execute the approved operation. The calling controller/ARP workflow remains responsible for enforcing that a risky action runs only after an affirmative decision.

### Files picker and clipboard

- External file/folder access can only be granted from the app UI with **Grant Access to File** / **Grant Access to Folder**. The app persists security-scoped bookmarks for those user-selected items.
- `bookmarks_list`: list the bookmarks currently granted by the user.
- `bookmark_import`: copy a selected external item into `Documents/LSM`.
- `bookmark_export`: copy a sandbox item into a bookmarked external folder.
- `clipboard_status`: report whether remote clipboard reads are locally enabled.
- `clipboard_write`: write bounded text to the iOS pasteboard.
- `clipboard_read`: read bounded text only while the app is foregrounded and only after the user enables **Allow Remote Clipboard Read** locally. iOS may still show its own paste privacy UI.

A remote action cannot open the Files picker or enable clipboard reads.

### Binary and image transfer

The mobile app does not put large media payloads into `mobile_action` JSON. It implements the existing LSM transfer wire tools used by `remote_transfer` and `image_view`:

- `transfer_stat`
- `transfer_read_chunk`
- `transfer_begin_write`
- `transfer_write_chunk`
- `transfer_finish_write`
- `transfer_abort_write`
- `transfer_upload_url`
- `transfer_download_url`

Transfers are constrained to `Documents/LSM`. The worker supports both the controller relay/chunk wire and HTTP transfer tickets, enforces a 4 MiB chunk limit, and verifies expected byte size and SHA-256.

Examples after the worker is online:

```text
remote_transfer(
  source_machine="morrow-iphone",
  source_path="Captures/photo.jpg",
  destination_path="/tmp/iphone-photo.jpg"
)

image_view(machine="morrow-iphone", path="Captures/photo.jpg")
```

## Share Extension

The optional `LSMMobileWorkerWithShare` target embeds **Send to LSM**, an iOS Share Extension that accepts files, images, PDFs, web URLs, and text. The extension writes a package into an App Group inbox; the containing app imports it into `Documents/LSM/Shared`, after which normal `remote_transfer` and `image_view` work without a separate media protocol.

The current Personal Development Team cannot provision the App Groups entitlement. Therefore:

- `LSMMobileWorker`: default target, no App Group, remains signable/installable with the current Personal Team.
- `LSMMobileWorkerWithShare`: App Group + embedded Share Extension; unsigned iPhoneOS SDK builds are validated now, and signed builds require a Developer Team that supports App Groups.
- `shared_inbox_import` exists for the share-enabled build and is not advertised as a capability by the default build.

## App Intents / Shortcuts

The app contributes Shortcuts/Siri actions for:

- **Check In LSM Worker**: run one bounded controller check-in and process immediately available work.
- **LSM Worker Status**: report whether the device is paired and its most recent worker state.
- **Open LSM Worker**: foreground the app.
- **Save Text to LSM Inbox**: put Shortcut input into the local mobile inbox.
- **Open LSM Code Scanner**: foreground LSM Worker and start the locally initiated scanner after Camera permission was already granted.
- **Last LSM Scanned Code**: return the last locally scanned QR/barcode value.

The intents reuse the same Keychain identity and job runtime as foreground polling; they do not expose or duplicate the bearer token and do not silently request new privacy permissions.

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

Ordinary remote jobs preserve the old offline behavior when APNs is absent: they are not queued indefinitely for a sleeping phone. Phase 4's explicit deferred `notify` / `send_to_mobile` path is different: those small controller events may be persisted until their bounded TTL and are delivered on the next authenticated phone poll. Without APNs, delivery therefore waits until iOS grants background runtime or the user reopens the app.

## Agent-interruption and job-completion notifications

LSM cannot observe ChatGPT's exact platform-side per-turn execution budget and does not receive an official "turn timeout" callback. The controller therefore does **not** claim to know the platform countdown.

For an active Goal, LSM already maintains its own 15-minute execution lease (`PLAN_EXECUTION_LEASE_S = 900`). Phase 4 runs an independent controller watchdog: when a Goal is still unfinished, has no in-flight tool calls, and crosses that lease without fresh agent activity, the controller queues an `agent_interrupted_or_expired` event for mobile workers. The notification explicitly says that the ChatGPT turn **may** have been interrupted and that auto-continuation is due. If the configured continuation budget is exhausted while work remains, a separate attention event is queued.

Tracked shell jobs are deterministic. `job_start(..., notify_on_finish=true)` now produces a stable `job_completed` event when that attempt reaches a terminal state; the controller/mobile pipeline acknowledges and deduplicates it. New remote Mac/Linux workers forward their opt-in completion events independently of the ChatGPT turn, so the notification can still be generated after the original assistant execution has stopped. Historical jobs created before this delivery mechanism are not replayed on upgrade.

With the current Personal Team build, these events are durable but cannot APNs-wake a fully suspended iPhone. If the app is foreground/polling they normally arrive within one poll cycle; otherwise they appear when the app next receives background runtime or is opened. A future push-capable Developer Team can use the already implemented APNs wake path for lower-latency delivery.

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
- Files bookmarks can only be created from the local document picker; remote jobs may use only already-granted bookmarks.
- Remote clipboard reads are locally opt-in and foreground-only.
- Approval prompts require the app foreground and return only the human decision; they never execute the approved operation themselves.
- Camera capture also requires the app to be foregrounded.
- `open_url` accepts only HTTP/HTTPS.
- Network probes are bounded and avoid private/local destinations by default.
- QR/barcode capture can only be initiated locally; remote actions can only read the last result.
- Deferred controller events are bounded, TTL-limited, acknowledged, and deduplicated.
- Session-interruption notifications are based on LSM's own 15-minute Goal lease and never claim access to ChatGPT's private platform timer.
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

Compile the Share Extension variant without signing:

```sh
xcodebuild \
  -project ios/LSMMobileWorker/LSMMobileWorker.xcodeproj \
  -scheme LSMMobileWorkerWithShare \
  -configuration Debug \
  -sdk iphoneos \
  CODE_SIGNING_ALLOWED=NO \
  build
```

A signed share-enabled build requires a provisioning team that supports App Groups. `PushDebug` on the share-enabled target additionally requires Push Notifications.

For a physical iPhone with the current Personal Team, build/install the normal `LSMMobileWorker` `Debug` configuration. The Phase 4 app version is `0.4.3`. `mobile.controller_events` is an explicit capability marker; controllers must not deliver event/ACK poll extensions to older iOS workers that do not advertise it.
