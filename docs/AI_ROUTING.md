# Direct AI and typed decisions

Onboarding and Settings contain **Direct AI connections**. Expand Gemini, NVIDIA NIM or OpenRouter, enter a key and save it. Vision and text model IDs are editable. **Test Connection** sends a small structured text request to that provider only and displays the measured response latency. It never silently tests another key; the probe does not establish image accuracy or phone performance.

**Scan using saved API keys** and **Parse product text** work before cloud sign-in or backend pairing. A photo requires consent before upload. In mobile mode, the request goes directly to configured AI providers. For an existing local or remote store, suggestions enter the review screen; unbound previews create no inventory. [Standalone mobile](STANDALONE_MOBILE.md) now adds local profiles, SQLite store management and on-device monitoring, with the documented pose and device-verification limits.

## Credentials

Android/iOS use `flutter_secure_storage`; its Web implementation encrypts values with WebCrypto/AES-GCM. Web requires HTTPS or localhost. Browser/provider CORS policy may prevent a direct request; this is shown as a connection failure. There is no backend credential relay. Keys never enter the configuration JSON, ledger, owner cache, provider health history or error messages. Removal writes an empty record so a compile-time key does not reappear.

Personal builds can optionally supply `--dart-define=GEMINI_API_KEY=...`, `--dart-define=NVIDIA_NIM_API_KEY=...` and `--dart-define=OPENROUTER_API_KEY=...`. Runtime entries take precedence. Compile-time keys are recoverable from distributed app/Web bundles; use runtime entry for builds shared with others. Never add secret values to tracked build files.

Server mode accepts `GEMINI_API_KEY`, `NVIDIA_NIM_API_KEY`, `OPENROUTER_API_KEY` or their `SHELFSIGHT_` aliases through its private environment. Model overrides and optional compatible endpoints are documented in `server/.env.example`. Mobile keys are never uploaded to ShelfSight's server.

## Provider protocol

Canonical provider profiles, JSON schemas, response limits, fallback models and decision policies live in `app/assets/defaults.json`. Models are defaults, not guarantees of current account access.

| Provider | Defaults | Structured request |
| --- | --- | --- |
| Gemini | `gemini-2.5-flash` | `generateContent`, JSON MIME, native `responseSchema`, inline image bytes |
| NVIDIA NIM | `meta/llama-4-maverick-17b-128e-instruct` | Chat Completions, image data URL, strict `response_format.json_schema` |
| OpenRouter | `google/gemini-2.5-flash` | Chat Completions, model fallback array, required structured-output support, ShelfSight attribution headers |

Provider failures, timeouts, refusals, malformed JSON and invalid schemas trigger failover to another configured key. An explicit preference is tried first. Each configured provider gets at most one bounded attempt; connection tests get exactly one. A single attempt defaults to 25 seconds. Up to three attempts can therefore take 75 seconds. Only validated successful responses update successful health history. Error rates and measured latency inform subsequent routing; they are not business analytics. Requests do not downgrade to unstructured output when schema enforcement is unavailable.

See the official [Gemini API](https://ai.google.dev/api/generate-content), [NVIDIA model page](https://build.nvidia.com/meta/llama-4-maverick-17b-128e-instruct/modelcard), and [OpenRouter model fallbacks](https://openrouter.ai/docs/guides/routing/model-fallbacks).

## Laya choice, score and noul

`LayaDecisionService` exposes `choice`, `score`, `noul` and a combined `assess`. Routing selects a configured provider and its task-specific model using recent errors/latency. The severity rubric is ordered `normal`, `watch`, `urgent` with values from 0 to 2.

Set `LAYA_ENDPOINT_URL` to a self-hosted Laya origin or full `/v1/systemone` URL. `LAYA_API_KEY` is optional. HTTPS is required except loopback HTTP. The backend uses the documented [Laya HTTP wire protocol](https://github.com/NandhaKishorM/laya/blob/main/docs/http-api.md): `state`, typed `questions`, and parsed `answers`. Malformed, truncated or unavailable responses fall back to deterministic evidence rules. Laya receives no provider keys. Its checkpoint cannot introduce arbitrary provider models or grant eligibility to unsupported actions.

Offline values marked `deterministic_policy` are rule truth values (0/1), not statistically calibrated forecasts. Missing evidence yields `p_true: null`. Values returned by Laya are marked model-reported and unvalidated on this store's traffic. Empirical calibration requires a labeled evaluation set; this repository does not claim one exists.

## Ledger-grounded recommendations

Open **Ledger-grounded recommendations** on the dashboard and explicitly request a review. Mobile reads immutable owner/server-scoped SQLite event copies. Authenticated event synchronization and monitoring acknowledgements populate that ledger. Web uses a tab-local copy of authenticated server SQLite events; it does not claim durable browser SQLite storage. `POST /v1/stores/{id}/decisions` independently reads the authenticated owner's server SQLite records and is rate limited.

Replay provenance, invalid/future records, stale counts, incomplete inventory scope and insufficient visit/coverage evidence cannot justify alerts. Shelf totals require a fresh latest count for every current item and an exact inventory scope match. Coverage intervals are merged so overlapping observations cannot inflate exposure. A zero probability threshold cannot turn a false predicate into an alert. Decision thresholds remain editable through the shared Settings schema.

Every candidate recommendation names an owned shelf and the exact supporting event IDs. A generative provider can select from those candidates; unknown events, foreign shelves, duplicate citations, omitted supporting IDs or an altered disclaimer cause rejection and failover. If no generative provider succeeds, deterministic evidence-backed recommendations remain available. Empty evidence produces an empty plan without a generative request. A bounded review currently assesses at most 20 shelves and 10,000 ledger events; the response reports limited shelf scope and missing inventory evidence causes abstention.

Plans require human review and never alter stock, shelves or calibration automatically. Every plan includes:

> Pickup, put-back, and sales conversion are not measured in this build; decisions are grounded strictly in verified dwell, visit, and recorded stock ledger events.

Recommendations are bound to their originating store and identity; changing either hides prior recommendations.
