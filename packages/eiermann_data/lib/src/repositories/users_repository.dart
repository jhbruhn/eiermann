import 'dart:math';

import 'package:eiermann_models/eiermann_models.dart';
import 'package:pocketbase/pocketbase.dart';
import 'package:zugvogel_data/zugvogel_data.dart';

/// The team: who is in it, who may decide what, and who has left.
///
/// There is no self-registration anywhere in this app. An account exists
/// because a coordinator decided it should, which is why this repository has an
/// [invite] and no `register`. The server holds the same line in
/// `users.createRule`, so a client that grew one would be refused.
///
/// Nothing here deletes. A departed member's name still has to appear on every
/// visit they recorded, and `users.deleteRule` is null for exactly that reason
/// — [setActive] with `false` is the retirement path.
class UsersRepository extends PbRepository<AppUser> {
  UsersRepository(PocketBase pb)
    : _pb = pb,
      super(pb: pb, collection: 'users', fromRecord: AppUser.fromRecord);

  final PocketBase _pb;

  /// Everybody in the caller's org, deactivated accounts included.
  ///
  /// Unpaged, and that is a judgement about this product rather than an
  /// oversight: the concept describes a group small enough that every member
  /// walks the tour. A team roster that needed a second page would be a
  /// different app.
  ///
  /// The former members stay in the list rather than being filtered out. Who
  /// used to be on the team is the question this screen gets asked when an old
  /// visit names somebody nobody recognises.
  ///
  /// Scope is the server's: `users.listRule` pins the org against the STORED
  /// row, so there is no filter to pass and no way to widen it from here.
  Future<List<AppUser>> team() => list(sort: 'name,email');

  /// Creates an account and gets its owner a way to sign in.
  ///
  /// **The two-step shape is federfall's, and so is the reason for it.**
  /// PocketBase's `users` is an auth collection, so a create without a password
  /// is refused — an account has to be able to sign in the moment it exists. So
  /// the account is created with a throwaway password and the invitee is then
  /// sent a reset link, which is the credential-setting step. Nobody ever
  /// types, transmits or knows a password somebody else chose.
  ///
  /// **Where this diverges from federfall: when there is no mailer.** federfall
  /// hides its invite action entirely unless the server reports it can send
  /// reset mail, and treats a failed send as a half-done invite to retry — the
  /// invitee is left holding an account whose password is, in federfall's own
  /// words, unknowable. That is the right call for an organisation with an
  /// operator and an SMTP server. It is the wrong one here: this app is
  /// self-hosted by volunteer groups, plenty of which have no mailer at all,
  /// and "you cannot add anybody, ever" is not an acceptable resting state.
  ///
  /// So the throwaway password is not thrown away. It comes back in the
  /// [Invitation] alongside [Invitation.mailSent], and the coordinator passes
  /// it on the way this group already passes everything on. When the mail DID
  /// go out, the password is never shown and never used.
  ///
  /// Pass [sendResetEmail] false when the server reports no mailer
  /// (`ServerAuthOptions.passwordReset`) — attempting the send anyway costs a
  /// round trip to a guaranteed failure. A send that fails despite being
  /// attempted is not an error either: the account exists, and the password
  /// below is the way in.
  ///
  /// [name] is required, unlike in the schema. Every audit-shaped row in this
  /// database stores a text SNAPSHOT of its author, and an account with no name
  /// snapshots its email address into the visit history of every Spot it ever
  /// touches.
  Future<Invitation> invite({
    required String email,
    required String name,
    required UserRole role,
    required String org,
    String? phone,
    bool sendResetEmail = true,
  }) async {
    final address = email.trim();
    final password = generatePassword();
    final user = await create({
      'email': address,
      'password': password,
      'passwordConfirm': password,
      'name': name.trim(),
      'phone': phone?.trim() ?? '',
      'role': role.wire,
      'org': org,
      'is_active': true,
      // The roster shows who to ask, and an address only its owner can see is a
      // colleague nobody can reach. The server sets this too, for a create it
      // did not see the flag on — see `main.pb.js`.
      'emailVisibility': true,
      // Who let this person in. The field has existed since migration 001 for
      // this one use: months later, "how did this account get here" is a
      // question with no other answer.
      'invited_by': ?_pb.authStore.record?.id,
    });

    if (!sendResetEmail) {
      return Invitation(user: user, password: password, mailSent: false);
    }

    var mailSent = true;
    try {
      await _pb.collection('users').requestPasswordReset(address);
    } on Object {
      // Deliberately swallowed, and this is the whole divergence in one line.
      // The account EXISTS by now; retrying the invite would fail on a
      // duplicate address, and reporting a failure would leave the coordinator
      // with a broken-looking screen and a real account behind it. The password
      // is the answer, so the caller is told which of the two ways in applies
      // rather than being told the invite failed.
      mailSent = false;
    }
    return Invitation(user: user, password: password, mailSent: mailSent);
  }

  /// Sends the credential-setting link again.
  ///
  /// Never reports whether the address exists — the server refuses to say, so
  /// nobody can enumerate the team's addresses through it.
  Future<void> resendInvitation(String email) async {
    try {
      await _pb.collection('users').requestPasswordReset(email.trim());
    } on ClientException catch (e) {
      throw RepositoryException.fromClient(e);
    }
  }

  /// Ends or resumes somebody's access.
  ///
  /// Takes effect on a LIVE token, not at the next sign-in: `users.authRule` is
  /// `is_active = true` and PocketBase re-evaluates it on every authenticated
  /// request. That is the whole point of having the flag rather than deleting
  /// the row.
  Future<AppUser> setActive(String id, {required bool active}) =>
      update(id, {'is_active': active});

  /// Grants or withdraws the coordination.
  ///
  /// Refused by the server for your OWN row, coordinator or not — otherwise the
  /// last coordinator can lock the team out with one tap, and a stolen
  /// coordinator session becomes a permanent one. `main.pb.js` puts the stored
  /// value back rather than answering an error, so a client that tried anyway
  /// gets its own row back unchanged.
  Future<AppUser> setRole(String id, UserRole role) =>
      update(id, {'role': role.wire});

  /// A password worth passing on out of band when no mail can be sent.
  ///
  /// Sixteen characters from an unambiguous alphabet — no `O`/`0`, no `l`/`1`
  /// — because this string gets read out loud or retyped off a screenshot, and
  /// a character somebody has to guess at is a support call. Sixteen of these
  /// 56 symbols is about 93 bits, far past anything a rate-limited login can be
  /// walked through.
  ///
  /// [Random.secure] and never the default `Random()`: the default is seeded
  /// from the clock, so two invites issued in the same millisecond would get
  /// the same password.
  static String generatePassword() {
    const alphabet =
        'ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789';
    final random = Random.secure();
    return List.generate(
      16,
      (_) => alphabet[random.nextInt(alphabet.length)],
    ).join();
  }
}

/// A freshly created account, and which of the two ways in it got.
class Invitation {
  const Invitation({
    required this.user,
    required this.password,
    required this.mailSent,
  });

  final AppUser user;

  /// Whether the credential-setting mail actually went out.
  ///
  /// The screen shows one of two entirely different things depending on this,
  /// so it is a fact and not a hint: either "a link is on its way to them" or
  /// "here is the password, pass it on".
  final bool mailSent;

  /// The account's initial password, in the clear.
  ///
  /// Only ever shown when [mailSent] is false. It is knowable exactly once —
  /// the server keeps only its hash, so nothing, not this app and not the Admin
  /// UI, can produce it again.
  final String password;
}
