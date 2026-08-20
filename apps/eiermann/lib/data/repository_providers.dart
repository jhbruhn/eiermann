import 'package:eiermann_data/eiermann_data.dart';
import 'package:pocketbase/pocketbase.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:zugvogel_pb_client/zugvogel_pb_client.dart';

part 'repository_providers.g.dart';

/// The configured client. Every repository below hangs off this one await, so
/// switching servers rebuilds all of them at once.
Future<PocketBase> _client(Ref ref) => ref.watch(pocketBaseProvider.future);

@Riverpod(keepAlive: true)
Future<AuthRepository> authRepository(Ref ref) async =>
    AuthRepository(await _client(ref));
