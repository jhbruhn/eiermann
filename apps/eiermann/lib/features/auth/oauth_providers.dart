import 'package:eiermann/data/repository_providers.dart';
import 'package:eiermann_data/eiermann_data.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'oauth_providers.g.dart';

/// The OAuth2 providers the server offers, with the labels for their buttons.
///
/// Read only once `/info` has said there are any: `serverInfo.auth.oauth2`
/// carries the NAMES and is fetched anyway, this call adds the operator's
/// display names. So a password-only instance — the default — never makes it.
@riverpod
Future<List<OAuthProvider>> oauthProviders(Ref ref) async {
  final repo = await ref.watch(authRepositoryProvider.future);
  return repo.oauthProviders();
}
