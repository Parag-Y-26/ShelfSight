# Third-party components

ShelfSight application logic, setup/map/calibration flows, tracking/event integration and analytics are implemented in this repository. The supplied logo and mockups came from the user. No existing end-to-end retail product is included.

Dependency lock files record exact resolved versions. Components include Flutter/Dart (BSD-style licenses), Firebase SDKs, Google ML Kit via the community flutter-ml package (MIT wrapper), MediaPipe (Apache-2.0), FastAPI (MIT), Pydantic (MIT), OpenCV (Apache-2.0), Python (PSF), Riverpod (MIT), Dio (MIT), camera (BSD-3-Clause), image (MIT), cryptography (Apache-2.0/BSD), and google-genai/google-auth (Apache-2.0). Consult each upstream package for complete notices and transitive dependency terms.

Inter is bundled under SIL Open Font License; full notice: licenses/Inter-OFL.txt. Open Food Facts data is provided under ODbL with attribution to https://world.openfoodfacts.org; product images have their own attribution/share-alike requirements. Captured user images are preferred. Product lookup does not imply verified regulatory claims.

The locally downloaded detector is Google's EfficientDet-Lite0 int8 model linked by the official MediaPipe object-detector documentation. Model weights are not committed; runtime model URL/path/checksum are configuration. Its COCO training provenance does not establish accuracy on a particular store. Gemini and Firebase are hosted services subject to their own service terms and quotas. Laya is not installed or used by this build.
