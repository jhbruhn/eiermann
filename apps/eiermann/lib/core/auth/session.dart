import 'package:eiermann/data/repository_providers.dart';
import 'package:eiermann_data/eiermann_data.dart';
import 'package:eiermann_models/eiermann_models.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:zugvogel_pb_client/zugvogel_pb_client.dart';

part 'session.g.dart';

/// The signed-in user, or null.
///
/// **Watch a field, not the object.** "Every auth change" includes a token
/// REFRESH, which happens on every resume — on web, every time the tab regains
/// focus. `ref.watch(currentUserProvider.future)` hands out a new future each
/// time, so a dependent recomputes in full even though nothing about the user
/// changed. Depend on what you actually use:
///
/// ```dart
/// final me = await ref.watch(currentUserProvider.selectAsync((u) => u?.id));
/// ```
@Riverpod(keepAlive: true)
Future<AppUser?> currentUser(Ref ref) async {
  final repo = await ref.watch(authRepositoryProvider.future);

  final sub = repo.changes.listen((_) => ref.invalidateSelf());
  // Disposed during the await above? onDispose would throw; cancel inline.
  if (!ref.mounted) {
    await sub.cancel();
    return repo.currentUser;
  }
  ref.onDispose(sub.cancel);

  return repo.currentUser;
}

/// Adapts this app's [AuthRepository] to the seam zugvogel's session upkeep
/// works against.
class _EiermannSession implements PbSession {
  _EiermannSession(this._repo);

  final AuthRepository _repo;

  @override
  Stream<void> get changes => _repo.changes;

  @override
  Future<void> refresh() => _repo.refresh();
}

/// Overrides zugvogel's session seam with this app's repository.
///
/// Wired in the ProviderScope so `sessionRefreshProvider` can roll the token
/// without the library knowing anything about [AppUser].
@Riverpod(keepAlive: true)
Future<PbSession> eiermannSession(Ref ref) async =>
    _EiermannSession(await ref.watch(authRepositoryProvider.future));
