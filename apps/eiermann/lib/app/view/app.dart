import 'package:eiermann/config/app_environment.dart';
import 'package:eiermann/l10n/l10n.dart';
import 'package:eiermann/routing/router.dart';
import 'package:eiermann/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zugvogel_ui/zugvogel_ui.dart';

class App extends ConsumerWidget {
  const App({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return MaterialApp.router(
      // Root of the state-restoration tree, paired with the router's own
      // restorationScopeId: this is what brings back the screen that was open
      // after Android reclaims the process.
      restorationScopeId: 'app',
      // Flavored name (e.g. "[DEV] Eiermann") for the window/tab title.
      title: AppEnvironment.appName,
      theme: AppTheme.light,
      darkTheme: AppTheme.dark,
      // Follow the device's language preference. German is the design language
      // and stays the fallback for anything we do not ship — see
      // `resolveAppLocale`.
      localeListResolutionCallback: (locales, _) => resolveAppLocale(locales),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      routerConfig: ref.watch(routerProvider),
      // Above the router, so the offline strip is ONE instance for the whole
      // app: it holds its position across every navigation, and it reaches the
      // routes pushed outside the navigation shell — setup and login — which is
      // exactly where finding out late costs the user something.
      builder: (context, child) => OfflineNotice(child: child!),
    );
  }
}
