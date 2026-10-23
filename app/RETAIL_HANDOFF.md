# Retail UI handoff

Implemented in `lib/screens/store_setup.dart`, `shelf_scan.dart`, `shelf_results.dart`, `product.dart`, and `analytics.dart`. Rendered copy is in `assets/l10n/retail_en.arb`; layout uses the shared theme tokens and widgets.

## Working behavior

- Configuration-owned store types/goals/currencies/units and user-entered names, shelf counts, floor dimensions and IANA time zone. Explicit controller validation covers fields scrolled outside the lazy form. A store created before a connection interruption is reused on retry.
- Shelf camera capture, retake, permission-error/manual fallback and explicit consent before sending the selected still to the laptop/Gemini scan endpoint. Temporary shelf captures are deleted when the screen closes.
- Editable scan drafts; dynamic front-view rows/slots synchronized with list selection; user-counted quantities; correction controls; removal of unsaved false-positive suggestions; dynamic shelf creation and switching. Rescans merge identified existing names/barcodes instead of duplicating them. Unmatched position conflicts require explicit correction. Existing stock is never silently deleted by a rescan.
- Product camera capture and local ML Kit EAN/UPC/QR reading, product lookup, manual fallback, captured thumbnail, editable optional details/nutrition, row/slot/quantity and persisted product/item mutations. QR data is never launched as a URL. New barcode input invalidates previous catalog identity and details; late lookup responses cannot apply to a changed code.
- Product edits preserve the product's recorded price denomination. Changing currency clears the entry instead of converting or relabelling it. A legacy amount with missing denomination is retained without assigning the current store currency.
- Analytics queries actual server aggregates for config-driven presets and Custom dates. Date boundaries use device-local calendar dates converted to UTC, as stated in the UI. Cached results are scoped through the core owner/server cache and labelled with their update time. Shelf visits, dwell, coverage, inventory and each empty state are explicit. Inventory values are recorded quantities. Sales/picks/put-backs display “Not measured in this build.” No trends or product-level gaze are fabricated.
- CSV is explicitly **copied to the clipboard**. The UI does not claim a file was saved.

## Integration

- `ProductScreen` returns `true` through Navigator when a save completes; callers refresh/merge their snapshot accordingly.
- Shelf Save goes to `/map?shelf=<id>`; scan-next goes to the next configured shelf. Constructors follow `docs/CONTRACT.md`.
- Core owns auth, certificate pinning, identity generation, API/cache isolation, main routing, base theme, configuration and shared card components. Server owns event recording, analytics computation, provider execution and validation. There are no fake business fixtures in production paths.

## Validation and evidence

- `test/retail_widgets_test.dart` contains 15 widget tests, including required user quantity before writes, correction API behavior, repeat scan deduplication, cached-A to unknown-B identity safety, identity changes during a multi-step save, pending-camera lifecycle recovery, known/unknown price denomination preservation, event-empty analytics, UTC query boundaries and CSV requests.
- Four readable Flutter-rendered golden frames are in `test/goldens/retail_setup.png`, `retail_shelf.png`, `retail_product.png`, and `retail_analytics.png`. Tests load actual Inter and MaterialIcons fonts. Fixtures exist only in the test source. The frames were visually inspected for text/icon rendering, fit and overflow.
- The test harness uses synchronous translations loaded from the real ARB files because Flutter's fake-async `pumpAndSettle` can finish before a cached asynchronous bundle load completes.
- A Flutter widget test is not physical-camera, ML Kit hardware, real Gemini, Firebase-account, live monitoring or Wi-Fi reliability verification. Those acceptance checks remain part of final integration/hardware QA. No accuracy or latency benchmark is inferred from these tests.

## Deliberate limits

- Product row/slot positions use numeric inputs with a live placement preview; shelf front-view selection remains visual. No arbitrary floor drawing or unsupported pickup/touch settings are introduced.
- Analytics uses this device's time zone for date selection, not automatic IANA-zone conversion from store settings. This behavior is labelled in the screen.
- Rescans do not replace occupied product records automatically, and swapping two occupied positions is not atomic. The API's collision error is surfaced; use a free position while correcting placement.
- Existing item/catalog deletion is not exposed by these screens; unsaved suggestions can be removed and entire owned-store deletion is handled by core settings.
