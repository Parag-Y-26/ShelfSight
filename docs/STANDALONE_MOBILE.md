# Standalone mobile

Android and iOS default to `standalone_mobile`. Save a Gemini, NVIDIA NIM or OpenRouter key in onboarding and choose **Start Standalone Mobile Mode**. The local profile uses the operating-system app sandbox; it is not a cloud account or a password-protected multi-user login. Its identifier and preferences are stored in secure storage. An optional Supabase login remains available. No FastAPI URL, pairing token or cloud-auth initialization is required for the local profile.

The last active standalone identity can also resume offline after an optional cloud login. It resumes as a device-local profile, which does not grant remote API authorization. Explicit sign-out or a switch to remote mode deactivates this automatic standalone resume.

Stores, floors, shelves, products, shelf items, inventory corrections, camera calibrations, monitoring sessions, visit/coverage events and autonomous recommendations persist in `shelfsight_standalone_v1.db` using sqflite. The ten explicit tables are `stores`, `floors`, `shelves`, `products`, `shelf_items`, `inventory_events`, `camera_calibrations`, `monitoring_sessions`, `visit_events`, and `autonomous_decisions`. Records preserve the server JSON contract. The current Python implementation physically stores its logical entities in `objects` and `events`; it has not been migrated to these ten tables.

All screen data operations use `ShelfSightRepository`. `StandaloneMobileRepository` executes SQLite transactions. `RemoteServerRepository` delegates to the existing authenticated HTTPS/WebSocket transport. Settings can switch the device execution mode or open **Use Remote Server Mode** for hosted/LAN pairing. Local and remote records are separate; switching mode does not synchronize or upload the local ledger. Signing out keeps standalone business records on this device. The explicit delete-store operation deletes that store and its dependent rows. App uninstall/device storage deletion removes local data; no backup/sync is implied.

## Camera behavior

The default is 5 samples/second at a maximum dimension of 640 pixels, adjustable through the existing configuration hierarchy. There is one in-flight inference and at most one pending frame. Android buffers are resized into NV21; iOS BGRA buffers are resized and physically rotated upright. No JPEG file or cloud vision call is used for monitoring. Both ML Kit object detection and the bundled base pose model execute on the device.

The default ML Kit object categories do not identify people. ShelfSight therefore requires confident shoulder, hip and ankle pose landmarks before accepting a person observation; generic object boxes alone never become visits. ML Kit's base pose detector follows the prominent person. This implementation does **not** guarantee crowded multi-person coverage, or count a body whose feet are obscured. Landmark likelihood is not an empirically calibrated person probability. See [ML Kit object detection](https://developers.google.com/ml-kit/vision/object-detection) and [pose detection](https://developers.google.com/ml-kit/vision/pose-detection).

`BottomCenterIoUTracker` ports the server association and visit state machine: expire tracks before matching, greedily associate by IoU/distance, project bottom-center into normalized, non-overlapping camera rectangles, enforce per-shelf confidence/dwell/grace settings, and finalize at the last observed in-zone timestamp. Camera loss, rotation, backgrounding, deliberate stop and interrupted-process recovery finalize eligible open stays as incomplete. Coverage is derived only from processed camera frames; long gaps create separate intervals. Visits have `provenance: live_camera`. The explicitly enabled labeled evaluation replay remains separate from live analytics and decision evidence.

Inference and ledger processing time is measured and shown on the monitoring screen. **Less than 100 ms is a target, not a verified guarantee**; actual device, scene, resolution and sampling settings determine latency. Neither a compilation nor mocked detector tests establish camera accuracy or mobile performance.

Temporary shelf/product camera files are consumed into memory and deleted (Web object URLs are revoked) before remote inference or subsequent user review. A product photo is persisted only when the user saves that product.

## Catalog and recommendations

EAN/UPC scanning uses ML Kit on-device. Lookup checks owner-scoped local products first, then directly requests `https://world.openfoodfacts.org/api/v2/product/{barcode}.json`, with bounded response size and timeout. Catalog misses and offline errors lead to manual entry. Missing price, allergens, nutrition and certification remain unknown; no store price or health claim is inferred. Imported public data is attributed to Open Food Facts. See its [API usage and attribution guidance](https://openfoodfacts.github.io/openfoodfacts-server/api/).

Local decisions use the actual SQLite inventory/visit/coverage ledger and persist the resulting reviewed plan. They keep real event/shelf citations and the mandatory measurement disclaimer. With no usable provider/network they use the deterministic evidence-gated fallback. Pickup, put-back and camera-derived sales remain unmeasured.

## Verification

Run host checks from `app/`:

```powershell
flutter analyze --no-pub
flutter test --no-pub --coverage
flutter build apk --debug --target-platform android-arm64 --split-per-abi
flutter build web --no-wasm-dry-run
```

With a connected Android/iOS device, run the native SQLite/navigation smoke:

```powershell
flutter test integration_test/standalone_sqlite_test.dart -d DEVICE_ID
```

It uses test-only credentials, spends no provider tokens, forbids server calls and cleans up its test store. It is not a real-camera acceptance test. iOS requires macOS/Xcode, CocoaPods as needed by the plugins, a signing team and iOS 15.5 or later.

For physical-device acceptance:

1. Start without a server URL, enter a provider key, and launch standalone. Use airplane mode for local operations; enable internet only when intentionally testing an AI or Open Food Facts request.
2. Create a store/floor/shelf, place it on the map, manually add a product and counted stock, and configure a camera interaction rectangle. Verify missing catalog fields show unknown.
3. Keep a consenting visible subject's feet inside the rectangle for longer than the configured dwell cutoff, then stop. Confirm a real visit ID/shelf ID, `live_camera`, observed dwell and incomplete finalization. Check zero transmitted frame bytes and record measured processing time; do not infer it from FPS.
4. Background, rotate and force-stop/reopen the app. Confirm intervals do not bridge downtime, and completed/eligible interrupted stays are not duplicated.
5. Reopen setup, inventory, map, analytics, monitoring events, recommendations and settings. Confirm persisted quantities, geometry, calibration records, event citations, saved recommendations and overrides. The scan/auth/connection screens represent device capabilities and profile/mode preferences rather than fabricated observations.
6. Switch to optional remote mode and back. Confirm separate records; sign out/in to the same local profile and confirm local persistence. Delete the test store and verify its records disappear.

Device acceptance and iOS compilation must be reported separately from host unit tests and Android/Web builds.
