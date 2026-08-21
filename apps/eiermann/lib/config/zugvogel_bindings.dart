import 'package:eiermann/config/app_environment.dart';
import 'package:eiermann/config/map_config.dart';
import 'package:eiermann/l10n/l10n.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:zugvogel_pb_client/zugvogel_pb_client.dart';
import 'package:zugvogel_ui/zugvogel_ui.dart';

export 'package:zugvogel_pb_client/zugvogel_pb_client.dart'
    show PbClientConfig, defaultPbClientConfig;
export 'package:zugvogel_ui/zugvogel_ui.dart' show defaultZugvogelStrings;

/// Everything zugvogel needs to know about *this* app.
///
/// The library holds no configuration and reads no compile-time define
/// (injection boundary 3), so every environment value it uses arrives from
/// here. One place, because a second would be a second answer to "which
/// server?".
PbClientConfig eiermannPbClientConfig() => PbClientConfig(
  // Derives the /api/eiermann/info route, the identity marker the client
  // requires before accepting a server, and the `eiermann.auth` /
  // `eiermann.serverUrl` storage keys. All three must agree, which is why they
  // come from one field — and why pointing this app at a federfall server is a
  // clean refusal rather than a client half-working against the wrong schema.
  service: 'eiermann',
  fallbackServerName: 'Eiermann',
  mapFallback: mapConfigFromDefines(),
  webBaseUrlOverride: AppEnvironment.pocketbaseUrlOverride,
  // http:// sends the bearer token in cleartext, so it is only tolerated on a
  // non-loopback host in development — where reaching a plain-http PocketBase
  // on the LAN is the point. Loopback is always allowed regardless.
  allowInsecureHttp: AppEnvironment.flavor == AppFlavor.development,
);

/// Binds this app's environment and localizations into zugvogel.
///
/// Called from `bootstrap()` for production and from
/// `test/flutter_test_config.dart` for the suite, so no individual widget test
/// has to know either seam exists.
void bindZugvogel() {
  defaultPbClientConfig = eiermannPbClientConfig();
  // This app's hooks write German prose aimed at the person doing the work —
  // "Ein Spot wird erst aktiv, wenn die Erkundung bei Zusage steht", "Eine
  // Pause braucht einen Grund". They enforce invariants no access rule can
  // express, so when one refuses a write it is the only party that knows why,
  // and replacing that sentence with "Die Daten konnten nicht gespeichert
  // werden" leaves the user stuck.
  //
  // Off by default in zugvogel, because federfall's hook messages are English
  // and some are addressed to a developer. Opting in is a promise about THIS
  // app's messages: a new hook message is user-visible copy, and gets written
  // as such.
  serverMessagesAreUserFacing = true;
  // Takes the context, not a ready-made instance, so the strings follow a
  // locale change: the lookup registers the dependency on Localizations.
  defaultZugvogelStrings = (context) => EiermannStrings(context.l10n);
}

/// Overrides for a `ProviderScope`. Empty today — [bindZugvogel] covers the
/// bindings — but kept as the seam, so wiring a fake in one place stays a
/// one-line change rather than a refactor.
List<Override> zugvogelOverrides() => const [];
