import 'package:eiermann_models/eiermann_models.dart';
import 'package:pocketbase/pocketbase.dart';
import 'package:zugvogel_data/zugvogel_data.dart';

/// Signing in, signing out, and who is signed in.
///
/// Thin on purpose: PocketBase owns the session, and this only maps its auth
/// record to [AppUser] and translates failures into the [RepositoryException]
/// the UI already knows how to render.
class AuthRepository {
  AuthRepository(this._pb);

  final PocketBase _pb;

  /// Emits whenever the session changes — sign-in, sign-out, token refresh.
  Stream<void> get changes => _pb.authStore.onChange;

  /// The signed-in user, or null.
  ///
  /// Read straight off the auth store rather than fetched: the record is
  /// already there, and a network round trip to answer "who am I" would make
  /// every cold start wait for it.
  AppUser? get currentUser {
    final record = _pb.authStore.record;
    if (record == null) return null;
    return AppUser.fromRecord(record);
  }

  bool get isSignedIn => _pb.authStore.isValid;

  /// Signs in with email and password.
  ///
  /// A deactivated account is refused by the collection's own `authRule`, which
  /// answers 400 — indistinguishable on the wire from a wrong password. That is
  /// deliberate on the server's side (it tells an attacker nothing), so the UI
  /// asks separately, after a successful sign-in, whether the account is
  /// active.
  Future<AppUser> signIn(String email, String password) async {
    try {
      final auth = await _pb
          .collection('users')
          .authWithPassword(email.trim(), password);
      return AppUser.fromRecord(auth.record);
    } on ClientException catch (e) {
      throw RepositoryException.fromClient(e);
    }
  }

  /// Re-issues the token with a fresh `exp`.
  ///
  /// A no-op when signed out. Clears the store ONLY on a 401/403 — a genuinely
  /// dead or revoked token. Any other failure (offline, server down) leaves the
  /// session alone: a transient blip must never sign somebody out.
  Future<void> refresh() async {
    if (!_pb.authStore.isValid) return;
    try {
      await _pb.collection('users').authRefresh();
    } on ClientException catch (e) {
      if (e.statusCode == 401 || e.statusCode == 403) {
        _pb.authStore.clear();
      }
      throw RepositoryException.fromClient(e);
    }
  }

  /// Asks the server to send a password-reset mail.
  ///
  /// Never reports whether the address exists — that would let anyone
  /// enumerate the team's addresses.
  Future<void> requestPasswordReset(String email) async {
    try {
      await _pb.collection('users').requestPasswordReset(email.trim());
    } on ClientException catch (e) {
      throw RepositoryException.fromClient(e);
    }
  }

  void signOut() => _pb.authStore.clear();
}
