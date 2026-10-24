# Run and host the ShelfSight API

## Local Windows server (no Google Cloud required)

The ShelfSight backend already runs locally from this repository. It uses Supabase Auth to verify account tokens, stores its SQLite database in the local runtime folder and serves the Android app over HTTPS on port 8443. The phone and PC must share a private Wi-Fi/LAN connection, and the PC must remain on while syncing. No Google Cloud account or public API deployment is required.

Copy `server/.env.example` to `server/.env` if needed, then set `SHELFSIGHT_SUPABASE_URL` and `SHELFSIGHT_SUPABASE_PUBLISHABLE_KEY`. The local server needs these public Supabase values to validate the signed-in user's bearer token. Do not put Supabase service-role credentials in this file or the APK.

Start the service from the repository root:

```powershell
./scripts/Start-Server.ps1
```

The launcher prints the HTTPS address and writes protected pairing details to `runtime/pairing.json`. In the Android app, sign in, choose **Pair your laptop**, and copy the local address, SHA-256 certificate fingerprint and one-use pairing secret from that JSON into the form. The app checks the server certificate against the supplied fingerprint before sending the Supabase access token; the code expires and can be used once. If Windows Firewall blocks access, allow inbound TCP 8443 only on the Private network profile. Do not open it on Public networks or configure a router port-forward. If automatic LAN address discovery selects the wrong interface, set `SHELFSIGHT_PUBLIC_ADDRESS=https://<PC-Wi-Fi-IP>:8443` in `server/.env` and restart.

### Configure vision providers on the server

ShelfSight keeps AI credentials on the backend. For NVIDIA's hosted NIM API, set `SHELFSIGHT_VISION_PROVIDER=nvidia-nim`, `SHELFSIGHT_VISION_API_KEY`, and `SHELFSIGHT_VISION_MODEL`. The base URL defaults to `https://integrate.api.nvidia.com/v1`; override it with `SHELFSIGHT_VISION_BASE_URL` only if NVIDIA supplies a different endpoint for the selected model.

For another provider, select `openai-compatible` and configure `SHELFSIGHT_VISION_BASE_URL`, `SHELFSIGHT_VISION_API_KEY`, and `SHELFSIGHT_VISION_MODEL`. The provider must implement OpenAI-style Chat Completions, accept image input through an `image_url` data URL, and return JSON matching ShelfSight's candidate schema. Custom HTTPS API paths are supported. In local-server mode, unencrypted HTTP is allowed only for loopback addresses (for example a NIM container published on `127.0.0.1:8000`); remote HTTP endpoints are rejected. If no compatible vision API is set, shelf scans remain unavailable while manual inventory entry continues to work. See NVIDIA's official [NIM Chat Completions and image-input example](https://docs.nvidia.com/nim/vision-language-models/1.7.0/examples/qwen/api.html).

## Optional Cloud Run demo

Google Cloud Run is an optional hosting route, not a prerequisite for the local setup. The root Dockerfile builds only the API and canonical configuration. Model binaries, databases and credentials are excluded from Docker and Cloud Build uploads. Without an externally provisioned verified model, person detection remains unavailable. For monitoring, provision the model independently on the host and set `SHELFSIGHT_MODEL_PATH` to that runtime path; the source deployment helper does not provision it. The API needs the Supabase URL and publishable key, and billing enabled on the Google Cloud project. The deployment script checks billing, deploys the API, verifies `/health`, and confirms unauthenticated store requests receive 401. From PowerShell in the repository root:

```powershell
./scripts/Deploy-CloudRun.ps1 -ProjectId 'your-cloud-project-id'
```

The existing helper supports Gemini through Google Secret Manager. The Python backend's NIM/OpenAI-compatible providers can also be set through their server environment variables and a Google Secret Manager binding, but this optional helper does not yet automate those provider bindings. Deployment incurs Google Cloud charges.

**Cloud Run demo storage is ephemeral.** Records can reset on restarts, scale-to-zero and new revisions. This is unsuitable for dependable inventory persistence. For persistent single-host operation, mount a protected durable directory at `SHELFSIGHT_RUNTIME_DIR` and run one worker behind an HTTPS/WSS reverse proxy. Durable multi-instance persistence is not implemented. Keep environment files, keys, certificates and runtime databases outside the build context.

## Android connection options

The app's **Pair your laptop** mode uses the local server's certificate pin and a one-use pairing code. The optional **Hosted API** mode expects an HTTPS origin such as `https://your-service.example`, without `/v1`, credentials, query or fragment. Supabase sign-in must be configured in `config/local.json` for the app and `server/.env` for the backend; the Android redirect `com.shelfsight.app://auth-callback` must be allowed in Supabase Auth URL Configuration. Never build server AI API keys into the mobile app.

Before relying on either route, test real-device sign-in, pairing/session expiry, camera calibration, scan review, monitoring recovery and persistence on the intended network. Health checks and synthetic tests do not establish those results.
