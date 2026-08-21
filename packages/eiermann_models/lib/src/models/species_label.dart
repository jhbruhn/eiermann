import 'package:freezed_annotation/freezed_annotation.dart';
import 'package:pocketbase/pocketbase.dart';
import 'package:zugvogel_core/zugvogel_core.dart';

part 'species_label.freezed.dart';

/// One row of the `species_labels` view: a species name this organisation has
/// actually written down, and how often.
///
/// The vocabulary behind every Artbezeichnung field, and it is a record of use
/// rather than a taxonomy. The app does not identify species — it asks the
/// person standing in front of the nest — so a curated list would go stale in
/// both directions at once: entries nobody here has seen in years, and never
/// the bird they are looking at.
///
/// The price is paid in the open: two spellings are two rows. "Dohle" and
/// "dohle" both appear, nothing normalises behind the user's back, and the
/// field says so. A normaliser that folds "Turmfalke" into "Turmfalken" is one
/// that will eventually fold two species together, and nobody will notice.
///
/// [id] is `org:label` — the view has no underlying record to point at, and the
/// label is the identity of a row. Nothing reads a species by id; it is here
/// because a PocketBase view needs one.
@freezed
abstract class SpeciesLabel with _$SpeciesLabel {
  const factory SpeciesLabel({
    required String id,
    required String label,
    String? org,

    /// How many findings and nests carry this exact spelling.
    ///
    /// The ordering of the suggestions, and the reason it is a count rather
    /// than a date: both tables under the view would have to supply a "last
    /// used", and `nests.updated` moves when a position hint is corrected. A
    /// column that claimed that precision would reorder the picker for reasons
    /// the reader cannot see.
    @Default(0) int usedCount,
  }) = _SpeciesLabel;

  factory SpeciesLabel.fromRecord(RecordModel r) => SpeciesLabel(
    id: r.id,
    label: pbString(r.data['label']) ?? '',
    org: pbString(r.data['org']),
    // `pbInt`, not `pbCount`: a row exists only because something used the
    // label, so zero is not a reading this view can produce — and reading it as
    // "nothing recorded" would be a lie either way.
    usedCount: pbInt(r.data['used_count']) ?? 0,
  );
}
