import 'dart:io';

import 'package:eiermann/l10n/l10n.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

/// Guards the one way this app's `MaterialApp`s get their localizations.
///
/// gen-l10n's own delegate list on `AppLocalizations` carries the legacy
/// `flutter_localizations` Material delegate, which `material_ui`'s widgets do
/// not look up. Using it compiles and runs; every Material string just falls
/// back to English, and nothing else in the suite would notice.
void main() {
  testWidgets('Material strings resolve in German through the app delegates', (
    tester,
  ) async {
    late MaterialLocalizations material;
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: appLocalizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('de'),
        home: Builder(
          builder: (context) {
            material = MaterialLocalizations.of(context);
            return const SizedBox();
          },
        ),
      ),
    );
    await tester.pump();

    expect(material.cancelButtonLabel, 'Abbrechen');
  });

  test('nothing hands a MaterialApp the generated delegate list', () {
    // Built from parts so this file does not match its own sweep.
    const generated =
        'AppLocalizations.'
        'localizationsDelegates';
    final offenders = <String>[];
    for (final root in ['lib', 'test']) {
      for (final file in Directory(root).listSync(recursive: true)) {
        if (file is! File || !file.path.endsWith('.dart')) continue;
        // The generated file declares the list; l10n.dart names it in the
        // comment that explains why it is not used.
        if (file.path.contains('l10n/gen/')) continue;
        if (file.path.endsWith('lib/l10n/l10n.dart')) continue;
        if (file.readAsStringSync().contains(generated)) {
          offenders.add(file.path);
        }
      }
    }

    expect(
      offenders,
      isEmpty,
      reason:
          'use appLocalizationsDelegates from l10n/l10n.dart — the generated '
          'list leaves material_ui on its English defaults',
    );
  });
}
