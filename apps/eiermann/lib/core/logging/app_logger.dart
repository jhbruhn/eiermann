import 'package:eiermann/config/app_environment.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:zugvogel_core/zugvogel_core.dart';

// AppLogger, LogLevel, scrubLogPayload and rootLogger come from zugvogel_core.
// Read scrubLogPayload's warning there before wiring a crash-reporting SDK into
// this: it is what stops a token or a contact's phone number leaving the
// device.
export 'package:zugvogel_core/zugvogel_core.dart'
    show AppLogger, LogLevel, defaultPiiLogKeys, rootLogger, scrubLogPayload;

part 'app_logger.g.dart';

/// App-wide logger. Quieter in production (info+), verbose in dev (debug+).
///
/// The provider stays here rather than in the library: it reads
/// [AppEnvironment.isProduction], and zugvogel holds no configuration
/// (injection boundary 3). The channel is passed for the same reason.
@Riverpod(keepAlive: true)
AppLogger appLogger(Ref ref) => AppLogger(
  channel: 'eiermann',
  minLevel: AppEnvironment.isProduction ? LogLevel.info : LogLevel.debug,
);
