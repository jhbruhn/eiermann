import 'dart:async';
import 'dart:ui';

import 'package:eiermann/config/app_environment.dart';
import 'package:eiermann/config/zugvogel_bindings.dart';
import 'package:eiermann/core/logging/app_logger.dart';
import 'package:eiermann/routing/url_strategy/url_strategy.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:zugvogel_pb_client/zugvogel_pb_client.dart';

Future<void> bootstrap(FutureOr<Widget> Function() builder) async {
  WidgetsFlutterBinding.ensureInitialized();

  // `intl`'s date symbols, which `DateFormat` needs before it will accept a
  // locale. Inside the widget tree flutter_localizations' delegate loads them
  // as a side effect, but anything formatting a date outside a BuildContext
  // runs before that — and without this it throws ArgumentError('Invalid locale
  // "de"'). Synchronous work behind an already-completed Future, so the await
  // costs a microtask.
  await initializeDateFormatting();

  // One configured logger drives the global error handlers, the provider
  // observer and the in-app appLoggerProvider, so every log shares config.
  final logger = AppLogger(
    channel: 'eiermann',
    minLevel: AppEnvironment.isProduction ? LogLevel.info : LogLevel.debug,
  );
  rootLogger = logger;

  FlutterError.onError = (details) => logger.error(
    details.exceptionAsString(),
    error: details.exception,
    stackTrace: details.stack,
    name: 'flutter',
  );

  // Errors that escape the Flutter framework (platform callbacks, async gaps).
  PlatformDispatcher.instance.onError = (error, stack) {
    logger.error('Uncaught error', error: error, stackTrace: stack);
    return true;
  };

  // Clean path-based URLs on the web (no-op on native).
  configureUrlStrategy();

  // What zugvogel needs to know about this app — the service name that derives
  // the /api/eiermann/info route, the identity marker and the storage keys,
  // plus the map fallback and this app's own words. The library reads no
  // compile-time define of its own (injection boundary 3), so this is the one
  // place those cross over. Before the ProviderScope, so no provider can be
  // read without it.
  bindZugvogel();

  runApp(
    ProviderScope(
      observers: [LoggingProviderObserver(logger)],
      overrides: zugvogelOverrides(),
      child: await builder(),
    ),
  );
}
