import 'package:eiermann/data/repository_providers.dart';
import 'package:eiermann_models/eiermann_models.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'rhythm_providers.g.dart';

/// The numbers the rhythm is currently using.
///
/// `keepAlive`, because these change a handful of times a year and everything
/// that wants to explain a due date needs them — re-reading per screen would be
/// a request per navigation for a value that is effectively constant.
///
/// The settings screen invalidates it after a write, which is the only moment
/// it can go stale from this client's point of view.
@Riverpod(keepAlive: true)
Future<RhythmSettings> rhythmSettings(Ref ref) async {
  final repo = await ref.read(rhythmRepositoryProvider.future);
  return repo.fetch();
}
