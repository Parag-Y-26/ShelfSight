# App core handoff

Implemented Supabase email/password registration/login/reset and Google Sign-In 7.x via Supabase ID-token sign-in, configuration-gated initialization, native certificate-pinned Dio and WebSocket transport, manual and QR laptop pairing, secure owner-specific session storage, UID/server-certificate-isolated SQLite snapshots, logout/revocation, reactive GoRouter guards, dashboard and settings, and merged ARB localization.

Core source was analyzed and formatted with the installed Flutter SDK. Live Supabase sign-in still requires the Android callback URL to be allowlisted in Supabase Auth; Google sign-in also requires its provider to be configured there. Physical camera QR capture and live TLS/WebSocket connections require an Android device and a reachable server; no live auth verification has been claimed.

`AppController.forTesting` accepts an injected fake `ApiClient` and supplied config/snapshot lists without initializing Supabase or opening SQLite. It is explicitly annotated for testing. Fake clients should override `paired`, API methods and server metadata. Production constructs the ordinary controller only.

Controller extras: `monitoringActive`, `markMonitoringActive(bool)`, `isOffline`, `cacheTimestamp`, `readCached(key)`, `cacheValue(key,value)`, `disconnect()`, `deleteSelectedStore()`. Monitoring must set active only after a valid processed frame acknowledgement and clear it on disconnect/stop. Cache reads return `{value, updated_at}`; namespace contains the UID, server address and pinned fingerprint.

Transport obtains its trust pin through pairing, accepts HTTPS origin addresses only, disables redirect following, and has no built-in trusted roots. Both certificate callbacks require the exact SHA-256 DER fingerprint and expected host/port. Pairing sends a Supabase access token; later REST and WebSocket requests send the opaque session token. QR aliases include the server CLI's `fingerprint_sha256`.

Build keys are `SUPABASE_URL` and `SUPABASE_PUBLISHABLE_KEY`; `GOOGLE_WEB_CLIENT_ID` is needed only for native Google sign-in. Android auth links use `com.shelfsight.app://auth-callback`, which must be allowlisted in Supabase Auth URL configuration. Missing configuration displays actionable setup instructions and disables authentication without introducing a bypass.

Strings load from `assets/l10n/core_en.arb`, `retail_en.arb`, and `monitoring_en.arb`. All business options and thresholds load from the configuration asset/server; no sample stores/products are seeded. Provider reasons and API error details are server data.

Remote configuration can supply `strings.en` resource overrides and new option label keys without an APK update. Config `locales` controls available English regional formats. The selected format is persisted in the owner/server cache and reset on logout. Theme uses the Inter asset that root downloads and licenses.
