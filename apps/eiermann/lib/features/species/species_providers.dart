import 'package:eiermann/data/repository_providers.dart';
import 'package:eiermann_models/eiermann_models.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'species_providers.g.dart';

/// Every Artbezeichnung this organisation has written down, most-used first.
///
/// One unpaged read, kept for the session, and filtered in the client. The
/// alternative — a server-side search per keystroke — would put a request
/// behind every letter typed in a stairwell, for a list of tens of rows.
@riverpod
Future<List<SpeciesLabel>> speciesLabels(Ref ref) async {
  final repo = await ref.watch(speciesLabelsRepositoryProvider.future);
  return repo.all();
}
