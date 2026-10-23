# ShelfSight

## Flutter Web and Cloud Run

The same Flutter app now builds for the browser. Build with `flutter build web --release --dart-define-from-file=../config/web.json` inside `app`, using a registered Firebase **web** app's client settings. The browser uses same-origin HTTPS, Firebase sign-in, tab-local caches, and one-use WebSocket tickets. Android keeps laptop pairing and certificate pinning.

The root Dockerfile serves Flutter Web and the authenticated API together. Include `runtime/models/detector.tflite` in the build context and set `SHELFSIGHT_FIREBASE_PROJECT_ID`; supply Gemini credentials through Secret Manager. The entry point reads Cloud Run's `PORT`. Cloud Run requires a billing-enabled project. Run a single worker and a maximum of one instance because monitoring state and SQLite are local to the instance. **This cloud demo's records can reset when the instance restarts; durable multi-instance persistence is not implemented.** Browser camera monitoring uploads frames to the cloud server, so obtain consent before starting it. Barcode entry is manual in browsers; ML Kit barcode scanning remains Android-only.

Validated locally: Flutter Web release compilation, 31 Flutter tests, 19 backend tests, and backend lint. Live cloud deployment and physical camera accuracy require separate verification.

Flutter Android retail setup and local Python shelf monitoring. This is an original demo application, not a production deployment. Google technologies: Firebase Authentication, ML Kit barcodes, Gemini shelf identification and MediaPipe local person detection.

## Start

1. Install Flutter stable, Android SDK and uv. Use Python 3.12. Run `uv sync --extra dev` inside `server` and `flutter pub get` inside `app`.
2. Copy `server/.env.example` to `server/.env`. Supply Firebase project ID, Gemini API key/model, the detector model path, and an HTTPS public LAN address reachable by the phone. Credentials and runtime pairing artifacts are ignored by Git.
3. Copy `config/local.example.json` to `config/local.json` and provide Firebase Android client metadata and Google web OAuth client ID. Firebase must enable email/password and Google providers, register Android package `com.shelfsight.app`, and register the APK signing SHA fingerprints.
4. From the repository root run `scripts/Start-Server.ps1`. It generates a local TLS certificate and a short-lived pairing QR under `runtime`. No camera frames are saved by monitoring.
5. Run `scripts/Build-App.ps1`; install the generated APK on Android. Sign in, scan the laptop pairing QR, enter your store/floor/shelf data, scan or manually add products, and place shelves on the map.
6. Mount the phone, open Monitoring, draw separate shopper interaction zones, save calibration, and start. Floor-map positions do not calibrate the camera. Recalibrate after moving or rotating the camera.

## Honest measurement boundaries

Visits are zone visits, not distinct customers or payments. Dwell time uses anonymous short-lived tracks. Recorded stock changes only through explicit inventory corrections. Pickup, put-back, touch, sales estimation, restaurant mode and Laya execution are unavailable. Empty analytics contain no fabricated values. Shelf identification is a Gemini suggestion requiring correction and user-entered quantities; it does not certify nutrition or regulatory status. Monitoring is foreground-only.

Config-driven options and defaults are in `config/defaults.json`. Store and shelf overrides take precedence. New option labels can be supplied under `strings.en` without an APK release. Run Build-App after editing bundled defaults; paired clients also refresh configuration from the server.

## Checks and evidence

Run `uv run pytest --cov=shelfsight` and `uv run ruff check shelfsight tests` from server. Run `flutter analyze` and `flutter test` from app. Run `uv run --python 3.12 python -m unittest discover -s tests` from the root for the evaluation harness.

Use `scripts/evaluate_visits.py --predictions events.json --truth labels.json --output results.json` to compare real events with independently labelled shelf_id/started_at/ended_at intervals. Optional `--frames acks.json` measures processing latency. Synthetic unit tests do not establish detector accuracy. Physical camera accuracy, ten-minute endurance, reconnect and offline acceptance must be separately measured before claiming them.

Use only product/shelf stills you are authorized to transmit to Gemini. Live monitoring stays on the local network. Firebase login and Gemini scans require internet; existing local device sessions expire according to configuration. OS account permissions protect laptop persistence; database encryption at rest is not claimed.

See docs/CONTRACT.md, docs/WORKBOARD.md, module handoffs and THIRD_PARTY_NOTICES.md for implementation details and remaining evidence.

## GitHub Android build

The manually triggered `Android verification and APK` workflow analyzes and tests the app, then packages a debug ARM64 APK. Configure repository Actions secret `SHELFSIGHT_FIREBASE_CONFIG` with the contents of your ignored `config/local.json`. It contains Firebase client build metadata; never place server Gemini credentials in this secret or in an APK. Successful runs publish the `shelfsight-android-demo` artifact for seven days. Register the signing SHA printed by that run in Firebase before testing Google sign-in. Each fresh runner may generate a different debug signing certificate. This is a demo build, not release signing.
