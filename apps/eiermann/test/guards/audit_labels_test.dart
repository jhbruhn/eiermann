@Tags(['guard'])
library;

import 'dart:convert';
import 'dart:io';

import 'package:eiermann/features/audit/audit_labels.dart';
import 'package:eiermann/l10n/l10n.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/harness.dart';
import 'sweep_sources.dart';

/// eiermann-uwd.4 — no recorded field may render as its raw column name.
///
/// **Why this is a guard and not a per-action test.** The audit registry lives
/// in `app_audit.js`, the words live in the ARB files, and nothing in either
/// language's compiler connects the two. Adding an action is one line of
/// JavaScript; forgetting its label is nothing at all, and the failure is a log
/// row reading `base_interval_days: 7 → 10` — perfectly functional, and written
/// for whoever wrote the schema rather than for whoever has to read it. A
/// per-action test would only ever cover the actions somebody remembered to
/// write a test for, which is the same set that gets a label.
///
/// So this parses the registry out of the hook and checks every entry, in BOTH
/// languages. German is the template and English is the one that quietly rots,
/// so checking only the template would pass while half the app is untranslated.
///
/// **What it deliberately allows.** Adding an action or a field stays additive:
/// nothing already recorded changes meaning, so it ships as `feat` and not as a
/// breaking change. RENAMING one is a wire change — the rows already written
/// keep the old spelling forever — and this test does not and cannot catch
/// that; the migration comment and the enum rule are what carry it.
void main() {
  late AppLocalizations de;
  late AppLocalizations en;

  setUpAll(() async {
    de = await germanStrings();
    en = await AppLocalizations.delegate.load(const Locale('en'));
  });

  /// The wire values of one registry object in `app_audit.js`.
  ///
  /// Parsed out of the source rather than hand-copied here, which is the whole
  /// point: a hand-copied list is a second registry, and it drifts silently in
  /// exactly the direction this test exists to prevent.
  List<String> registry(String name) {
    final source = File(
      '${repoRoot.path}/backend/pocketbase/pb_hooks/app_audit.js',
    ).readAsStringSync();

    final start = source.indexOf('const $name = {');
    expect(
      start,
      isNot(-1),
      reason:
          'no `const $name = {` in app_audit.js — the registry was renamed or '
          'moved, and this guard has been reading nothing ever since',
    );
    final end = source.indexOf('\n};', start);
    expect(end, isNot(-1), reason: '`const $name` is never closed');
    final body = source.substring(start, end);

    // `key: "wire_value",` — with the comment lines stripped first, so a wire
    // value quoted inside a comment does not become a registry entry.
    final withoutComments = body
        .split('\n')
        .where((line) => !line.trimLeft().startsWith('//'))
        .join('\n');
    final values = [
      for (final match in RegExp(
        r'^\s*\w+:\s*"([a-z0-9_]+)"',
        multiLine: true,
      ).allMatches(withoutComments))
        match.group(1)!,
    ];

    expect(
      values,
      isNotEmpty,
      reason:
          'parsed no entries out of `$name` — a sweep over nothing passes over '
          'anything',
    );
    return values;
  }

  test('every recorded ACTION has a word in both languages', () {
    final actions = registry('ACTIONS');
    // The registry is the contract, so its size is worth stating: if this drops
    // the day somebody reformats the hook, the test above has stopped reading.
    expect(actions.length, greaterThanOrEqualTo(10));

    for (final action in actions) {
      for (final (language, l10n) in [('de', de), ('en', en)]) {
        final label = auditActionLabel(l10n, action);
        expect(
          label,
          isNot(action),
          reason:
              '`$action` renders as its own wire value in $language. '
              'Add it to auditActionLabel and to both ARB files — a log row '
              'that says "spot_phase_changed" is a row written for the schema, '
              'not for the coordinator reading it.',
        );
        expect(
          label.trim(),
          isNotEmpty,
          reason: '$action is blank in $language',
        );
      }
    }
  });

  test('every recorded FIELD has a word in both languages', () {
    final fields = registry('FIELDS');
    expect(fields.length, greaterThanOrEqualTo(10));

    for (final field in fields) {
      for (final (language, l10n) in [('de', de), ('en', en)]) {
        final label = auditFieldLabel(l10n, field);
        expect(
          label,
          isNot(field),
          reason:
              '`$field` renders as its own column name in $language. '
              'Add it to auditFieldLabel and to both ARB files — this is the '
              'exact failure eiermann-uwd.4 exists for.',
        );
        expect(
          label.trim(),
          isNotEmpty,
          reason: '$field is blank in $language',
        );
      }
    }
  });

  test('the two languages actually differ somewhere', () {
    // The canary for the canary. Both lookups above would pass if `en` silently
    // resolved to the German bundle — every label would be non-raw in both
    // "languages" and the English half of the guard would be theatre.
    expect(
      de.auditTitle,
      isNot(en.auditTitle),
      reason:
          'the English bundle is answering with German. Every per-language '
          'assertion above is then checking the same strings twice.',
    );
  });

  test('a value is never rendered as its raw wire string', () {
    // The enum-shaped fields specifically. These are the ones where a raw value
    // is most misleading rather than merely ugly: `feral_pigeon` and
    // `protected` decide whether taking eggs out of a nest is legal, and a log
    // row nobody can read is a log row nobody checks.
    const enumValues = {
      'phase': ['prospect', 'active', 'paused', 'closed'],
      'role': ['member', 'coordinator', 'guest'],
      'species': ['protected', 'feral_pigeon', 'unknown'],
      'is_active': ['true', 'false'],
      'pause_auto_resume': ['true', 'false'],
      'closed_reason': [
        'netted',
        'permission_withdrawn',
        'building_gone',
        'no_pigeons',
      ],
    };

    for (final entry in enumValues.entries) {
      for (final value in entry.value) {
        for (final (language, l10n) in [('de', de), ('en', en)]) {
          expect(
            auditValueLabel(l10n, entry.key, value),
            isNot(value),
            reason:
                '`${entry.key}` renders the stored value `$value` raw in '
                '$language',
          );
        }
      }
    }
  });

  test('an empty value stays empty rather than becoming a word', () {
    // The absence of a previous value is a FACT — an invited account did not
    // exist a moment ago — and the screen has its own copy for it. A label
    // function that turned "" into "Unbekannt" would make that read as a value
    // somebody blanked.
    for (final field in ['phase', 'role', 'species', 'is_active']) {
      expect(auditValueLabel(de, field, ''), isEmpty);
    }
  });

  test('the ARB files carry every audit key in both languages', () {
    // Read as JSON rather than through the generated getters, because
    // gen-l10n's fallback is to emit the TEMPLATE string for a key the
    // translation lacks: `auditActionSpotDeleted` would answer "Spot gelöscht"
    // in English and the assertions above would be satisfied by German.
    Map<String, dynamic> arb(String name) =>
        jsonDecode(
              File(
                '${repoRoot.path}/apps/eiermann/lib/l10n/arb/$name',
              ).readAsStringSync(),
            )
            as Map<String, dynamic>;

    final german = arb('app_de.arb');
    final english = arb('app_en.arb');
    final missing = [
      for (final key in german.keys)
        if (key.startsWith('audit') && !english.containsKey(key)) key,
    ];

    expect(
      missing,
      isEmpty,
      reason:
          '$missing — present in the German template and absent from the '
          'English file. gen-l10n falls back to the template rather than '
          'failing, so the app would show German to an English reader and no '
          'other test would notice.',
    );
  });
}
