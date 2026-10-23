# App core handoff

Implemented Firebase email/password registration/login/reset and Google Sign-In 7.x, configuration-gated initialization, native certificate-pinned Dio and WebSocket transport, manual and QR laptop pairing, secure owner-specific session storage, UID/server-certificate-isolated SQLite snapshots, logout/revocation, reactive GoRouter guards, dashboard and settings, and merged ARB localization.

Core source was parsed and formatted with the installed Dart SDK. Firebase sign-in, Android secure storage, physical camera QR capture, and live TLS/WebSocket connections still require configured Firebase, a reachable server and an Android device; no such runtime verification has been claimed.

`AppController.forTesting` accepts an injected fake `ApiClient` and supplied config/snapshot lists without initializing Firebase or opening SQLite. It is explicitly annotated for testing. Fake clients should override `paired`, API methods and server metadata. Production constructs the ordinary controller only.

Controller extras: `monitoringActive`, `markMonitoringActive(bool)`, `isOffline`, `cacheTimestamp`, `readCached(key)`, `cacheValue(key,value)`, `disconnect()`, `deleteSelectedStore()`. Monitoring must set active only after a valid processed frame acknowledgement and clear it on disconnect/stop. Cache reads return `{value, updated_at}`; namespace contains the UID, server address and pinned fingerprint.

Transport obtains its trust pin through pairing, accepts HTTPS origin addresses only, disables redirect following, and has no built-in trusted roots. Both certificate callbacks require the exact SHA-256 DER fingerprint and expected host/port. Pairing sends a Firebase ID token; later REST and WebSocket requests send the opaque session token. QR aliases include the server CLI's `fingerprint_sha256`.

Firebase build keys are `FIREBASE_API_KEY`, `FIREBASE_APP_ID`, `FIREBASE_PROJECT_ID`, `FIREBASE_MESSAGING_SENDER_ID`, and `GOOGLE_WEB_CLIENT_ID`; optional auth-domain/storage-bucket keys are read from the environment. Missing configuration displays actionable setup instructions and disables authentication without introducing a bypass.

Strings load from `assets/l10n/core_en.arb`, `retail_en.arb`, and `monitoring_en.arb`. All business options and thresholds load from the configuration asset/server; no sample stores/products are seeded. Provider reasons and API error details are server data.

Remote configuration can supply `strings.en` resource overrides and new option label keys without an APK update. Config `locales` controls available English regional formats. The selected format is persisted in the owner/server cache and reset on logout. Theme uses the Inter asset that root downloads and licenses.
