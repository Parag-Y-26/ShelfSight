# Mobile screens and measurement contract

Android/iOS standalone mode uses the on-device SQLite repository. Optional remote mode uses the authenticated server repository and its separate dataset. No store observations are seeded.

| Screen | Behavior |
| --- | --- |
| Auth / connection | Masked Gemini, NVIDIA NIM and OpenRouter key cards; explicit Verify Key request with measured latency; Start on Mobile (Standalone); optional HTTPS server pairing. |
| Store setup | User-entered store name, currency, shelf count and floor dimensions. Canonical `width_m` / `length_m` persist alongside display units, including migration of existing mobile floors. Restaurant mode is Deferred / Unavailable. |
| Shelf scan | Camera/gallery input, privacy disclosure, next provider/model route through Laya and separately labeled last actual scan provider, validated `ShelfScanStructuredOutput`. Remote mode reports server routing without inferring availability from mobile keys. Gallery images are bounded, rotated upright and converted to JPEG with metadata removed. Identification requires explicit review. |
| Shelf results | Editable row/slot assignments with atomic swaps and counted initial stock. `INITIAL_STOCK` inventory events retain placement and quantity evidence. |
| Product | Live EAN/UPC ML Kit scanner; local catalog first, then Open Food Facts; manual editor. Missing price, allergens and nutrition remain unknown. |
| Store map | Pinch/zoom/pan InteractiveViewer, draggable/resizable shelves, zoom controls and numerical geometry editing. Confirmed geometry persists in SQLite. |
| Dashboard | Actual catalog counts and bounded recent ledger summary. Laya urgency can be insufficient evidence. LIVE requires a fresh processed camera frame; merely creating a monitoring session does not enable it. |
| Monitoring | Rectangular or convex polygon shelf zones, touch corner entry and numerical editing. Self-intersection, concavity, zero area and positive overlap are rejected. Person boxes and bottom-center points use the same upright frame as tracking. Explicit labeled replay remains separately badged and excluded from live aggregates. |
| Analytics | SQLite visit counts, mean/median dwell, shelf-zone coverage, recorded stock and explicit decision generation. Recommendations include review guidance, deterministic Laya score / noul evidence gates, and tappable real event citations. CSV uses a mobile share sheet or browser download. |
| Settings | Auto (Laya Router), provider/model/key controls, precise threshold entry plus sliders, shelf → store → default inheritance, and confirmed owner-scoped Delete All Store Data for the current backend. |

## Honest analytics

Pickup, put-back, sales conversion and actual product visibility are **Not measured in this build**. Visits count qualifying stays in calibrated shelf zones, not unique customers or purchases. Empty ledgers show zero visits, unknown dwell and No recorded events yet.

Recorded-slot zone coverage is a proxy: the interval union of calibrated shelf-zone coverage while the currently recorded row/slot assignment exists. It does not demonstrate that a product was visible. Legacy inventory observations without placement metadata have unknown slot coverage. Labeled replay is excluded from live analytics and decision evidence.

Laya probabilities are deterministic evidence gates, not empirically calibrated forecasts. Saved reviews can become historical; inspect their exact ledger citations and current stock before acting. Generative provider calls require explicit user action. Local camera tracking sends no frames to cloud AI.

## Accessibility and verification

Material 3 uses primary `#006874`, secondary accent `#00838F` and surface `#F8FDFF`. Body text and inline teal labels use the darker primary to maintain at least 4.5:1 on pale surfaces. Accent remains available with white foreground. Native labeled buttons, fields, sliders and tooltips supply semantics; the custom map/calibration canvases have labels and numerical alternatives. Forms scroll, respect safe areas and keyboard insets, and use padded touch targets.

Host tests exercise all business routes against real SQLite at 320×640 portrait and 568×320 landscape with 200% landscape text size; onboarding and connection additionally use 200% in both sizes. Flutter accessibility guidelines check labeled and 48-pixel tap targets in those views. Color-pair tests check text contrast. Golden images cover the main screen layouts. Further tests cover polygon geometry, frame freshness, native barcode channel payloads, image limits, floor migration, atomic planograms, exact event ownership and data deletion races.

```powershell
cd app
flutter analyze
flutter test
flutter build apk --debug --split-per-abi --target-platform android-arm64
flutter build web --release
cd ../server
uv run pytest
uv run ruff check shelfsight tests
uv run pip-audit
```

Host checks are not full WCAG certification. Physical Android/iOS acceptance is still required for TalkBack/VoiceOver traversal, live camera/barcode accuracy and latency, gallery permissions, rotation/background recovery, and share-sheet/file-save behavior. No sub-100ms performance claim follows from a configured sampling FPS. iOS compilation requires macOS/Xcode. See [the device acceptance steps](STANDALONE_MOBILE.md#verification).
