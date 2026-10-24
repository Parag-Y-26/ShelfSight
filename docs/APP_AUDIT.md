# ShelfSight verification audit

## Verified locally

- `flutter analyze --no-pub` completed with no issues and `flutter test --no-pub` passed 43 tests, including the local certificate-pinned pairing path, hosted API option, and Android Back regression.
- `scripts/Build-App.ps1` completed with the existing Supabase client settings and no hosted API URL. The ARM64 APK at `app/build/app/outputs/flutter-apk/app-arm64-v8a-debug.apk` was installed as an in-place update (`0.1.0`, version code `2001`) on the connected Android phone.
- Server lint and 11 focused vision-provider/security tests pass. Full pytest previously reported 36 passed and 1 failure: `test_event_only_inventory_analytics_slot_collision_and_csv` passes in isolation but fails in the full suite; this remains unresolved. A dependency vulnerability audit was not run.
- The repository evaluation harness ran 4 tests successfully.
- The local Windows HTTPS API is running at `https://192.168.0.104:8443`; `/health` returns `200` over loopback and LAN. The connected phone is on the same `192.168.0.x` Wi-Fi and can reach TCP port 8443. No Google Cloud deployment was used.
- The local server selects Gemini and has a nonempty Gemini credential; a metadata-only Google model-list request succeeded and listed the configured `gemini-3.8-flash` model. No paid image-generation request was made. Scan failures now surface the server's sanitized detail, and server logs record only error type/status metadata.

## Still unverified

- Docker Desktop was unavailable locally, so the container image has not been built and no Cloud Run deployment has been made.
- Live Supabase sign-in and end-to-end phone pairing have not been accepted. Supabase Auth must allow `com.shelfsight.app://auth-callback`; Google sign-in also requires configuring the Google provider.
- Live image identification through the configured provider, camera calibration, monitoring accuracy, reconnect behavior and persisted inventory have not been accepted on an Android device. The installed build and server restart still need a real shelf-photo scan to verify the full provider generation path.

Use [API hosting](CLOUD_DEPLOYMENT.md) for local Windows startup (no Google Cloud required) or the optional Cloud Run route, plus provider setup and device acceptance checks.
