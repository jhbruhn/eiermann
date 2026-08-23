import 'package:eiermann/data/repository_providers.dart';
import 'package:eiermann_data/eiermann_data.dart';
import 'package:eiermann_models/eiermann_models.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'team_providers.g.dart';

/// Everybody in the org, former members included.
///
/// One read for the whole screen, and unpaged — see [UsersRepository.team] for
/// why that is a statement about this product rather than a shortcut.
///
/// Deliberately NOT `keepAlive`: the roster is what a coordinator has just
/// changed, and a cached list is a list that still shows the role somebody was
/// demoted out of. Every write invalidates it explicitly as well; this only
/// removes the case nobody remembered to.
@riverpod
Future<List<AppUser>> team(Ref ref) async {
  final repo = await ref.read(usersRepositoryProvider.future);
  return repo.team();
}
