# ShelfSight for Android

ShelfSight uses Supabase Auth for sign-in and can connect to a Python API running on your Windows PC over your private Wi-Fi. **Google Cloud is not required.** A hosted HTTPS API is optional. Local API sessions use a one-time pairing code and certificate pin; the phone and PC must be on the same reachable network while the server is running. Supabase Auth remains an online dependency. ShelfSight's local server can call Gemini, NVIDIA NIM, or another vision-enabled OpenAI-compatible Chat Completions API. Direct AI tools can also use user-entered keys stored encrypted on the device, without Supabase sign-in or a backend. Server credentials remain private to the server.

## Run locally without Google Cloud

1. In Supabase Auth → URL Configuration, allow `com.shelfsight.app://auth-callback`. Email/password sign-in is supported; Google sign-in also requires enabling Google in Supabase Auth and configuring its client IDs.
2. Copy `config/local.example.json` to ignored `config/local.json` and fill `SUPABASE_URL` and the public `SUPABASE_PUBLISHABLE_KEY`. These two values are used by the mobile client and are not service-role secrets.
3. Copy `server/.env.example` to `server/.env` if you do not already have that file. Set `SHELFSIGHT_SUPABASE_URL` and `SHELFSIGHT_SUPABASE_PUBLISHABLE_KEY` there so the local API can verify signed-in users. Do not commit this file.
4. Optionally configure shelf-photo identification in `server/.env`. For hosted NVIDIA NIM, set `SHELFSIGHT_VISION_PROVIDER=nvidia-nim`, `SHELFSIGHT_VISION_API_KEY` to the NIM key, and `SHELFSIGHT_VISION_MODEL` to the exact model ID enabled for your account. Leave `SHELFSIGHT_VISION_BASE_URL` blank to use NVIDIA's hosted endpoint. For another OpenAI-compatible vision API, use `SHELFSIGHT_VISION_PROVIDER=openai-compatible` and set its HTTPS base URL, API key and vision-capable model ID. A local NIM container can use a loopback base URL such as `http://127.0.0.1:8000/v1`. The adapter sends an image and asks for structured JSON; arbitrary APIs that do not implement OpenAI Chat Completions with image input need their own adapter. Keep every provider key in `server/.env` or a server secret manager, never in `config/local.json` or the APK.
5. From the repository root, run `./scripts/Start-Server.ps1`. The server prints its HTTPS address and the path to `runtime/pairing.json`; it also creates a one-use pairing code and TLS certificate fingerprint. If address auto-detection is wrong, set `SHELFSIGHT_PUBLIC_ADDRESS=https://<your-PC-Wi-Fi-IP>:8443` in `server/.env` and restart.
6. Build and install the app with `./scripts/Build-App.ps1`, sign in, select **Pair your laptop**, and enter the address, fingerprint and pairing code from `runtime/pairing.json`. Pairing validates the exact certificate fingerprint and consumes the code. Keep the phone and PC on the same private Wi-Fi. If Windows Firewall blocks the connection, allow TCP port 8443 on the **Private** profile only; do not expose it to Public networks.

The local server writes SQLite data and protected TLS/pairing files under `runtime/`. Keep the server process running while using the app. Closing it stops API access; the phone may retain an offline snapshot, but cannot sync. Shelf scans remain unavailable until a vision provider and valid model are configured; product entry can still be done manually. A hosted NVIDIA API requires internet access from the PC. Self-hosted NIM requires suitable NVIDIA hardware/runtime; the Android app does not run the NIM model itself.

## Optional hosted API

Choose **Hosted API** on the app connection screen to connect to an already deployed HTTPS API instead of pairing a PC. The optional Google Cloud Run helper is in [API hosting](docs/CLOUD_DEPLOYMENT.md); it is not needed for the local setup above. Do not set `SHELFSIGHT_API_URL` in `config/local.json` unless you intend to use a hosted service.

## Purpose and limits

The implemented scope is store setup, editable shelf identification suggestions, barcode/manual products, recorded inventory, floor maps, anonymous shelf-zone visits, dwell time, analytics and CSV export. Inventory changes only through explicit corrections. Visits are zone visits, not unique customers or payments. Pickup, put-back, touch and sales estimation are unavailable. Empty analytics do not contain fabricated results.

Monitoring frames are sent over encrypted TLS to the configured ShelfSight API, processed in memory and discarded. Direct-mode scans go from the device to configured AI providers after consent; remote-mode scans go through the API to its configured providers. Shelf names, positions and quantities proposed by AI require human review.

This remains a demo. Existing Firebase users are not automatically imported: users need to create/confirm a Supabase account. Firebase passwords and old Firebase user IDs do not transfer, so data previously scoped to a Firebase UID may need an explicit migration/mapping before those users can access it. Camera accuracy, live sign-in, live vision identification, connection recovery and long-running Android monitoring require separate acceptance testing.

## Development checks

From `server`: `uv sync --extra dev`, `uv run pytest --cov=shelfsight`, and `uv run ruff check shelfsight tests`.

From `app`: `flutter pub get`, `flutter analyze`, and `flutter test`. From the repository root: `uv run --python 3.12 python -m unittest discover -s tests`.

The Python tests inject identity/detector providers. They validate behavior, ownership and event calculations, not physical detector accuracy. The evaluation script in `scripts/evaluate_visits.py` compares recorded intervals with independent labels when real measurements are available.

## Dynamic configuration

`app/assets/defaults.json` is the only maintained business configuration. Flutter bundles it directly and the backend reads the same file. It defines numeric defaults, allowed provider/mode choices, validation rules and migration aliases for older setting names. Android resources are generated at build time from the canonical `app/assets/logo.jpeg`.

Settings resolves shelf overrides, then store overrides, then device/global defaults. Device preferences and owner/server/store-scoped overrides are saved in secure local storage, including edits made offline. Monitoring requests carry a validated configuration snapshot so saved local overrides reach the server. Stop monitoring before changing settings; existing sessions retain their starting thresholds.

Android and iOS default to `standalone_mobile`; other platforms default to `remote_server`. Mobile mode supports direct photo identification and product text parsing with encrypted on-device AI keys, without backend pairing. Person detection and full offline store management are not implemented. Explicitly pairing or connecting an API selects remote mode. Settings and direct AI tools can be opened before sign-in.

AI selection supports `auto`, `gemini`, `nvidia_nim`, and `openrouter`. Onboarding and Settings accept encrypted device keys and editable model IDs. **Test Connection** reports live latency for the chosen provider only. Generative requests can fail over among configured providers after consent; `auto` uses recent provider errors and latency. Server deployments independently use their private environment keys. See [Direct AI and typed decisions](docs/AI_ROUTING.md) for setup, compile-time injection, provider payloads, local Laya configuration, evidence gates and verification limits.

**Run Labeled Evaluation Replay** is disabled by default and requires user-supplied labeled frame JSON. Every replay frame is badged `labeled_replay`. It reads supplied detections only, has no production detector/API/ledger access, and does not measure detector accuracy. Replay provenance is also excluded from backend business analytics.
