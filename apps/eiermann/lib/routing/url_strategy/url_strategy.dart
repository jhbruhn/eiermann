/// Configures clean path-based URLs on the web, no-op elsewhere.
///
/// The web implementation pulls in `flutter_web_plugins`, which only exists on
/// the web target, so the import is resolved conditionally.
library;

export 'url_strategy_io.dart'
    if (dart.library.js_interop) 'url_strategy_web.dart';
