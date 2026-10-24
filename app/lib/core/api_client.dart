// Remote transport only. Screen data operations use ShelfSightRepository via
// AppController.repository; standalone mode never calls this HTTP transport.
export 'api_native.dart' if (dart.library.js_interop) 'api_web.dart';
