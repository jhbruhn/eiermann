import 'package:flutter_web_plugins/url_strategy.dart';

/// Drop the leading `#` from web URLs so routes are real paths
/// (e.g. `/cases/42` instead of `/#/cases/42`).
void configureUrlStrategy() => usePathUrlStrategy();
