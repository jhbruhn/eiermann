import 'package:eiermann/core/auth/session.dart';
import 'package:eiermann_data/eiermann_data.dart';
import 'package:eiermann_models/eiermann_models.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zugvogel_ui/zugvogel_ui.dart';

// The busy/error lifecycle, the form key, runSave and the sheet shell all live
// in zugvogel_ui — every create/edit sheet in either app repeats the same
// try/catch tail and the same padding/scroll/title/error/save layout.
//
// The org guard could NOT move there: resolving "the signed-in user and their
// organisation" needs this app's own AppUser and its currentUserProvider, and a
// shared package that knew either would know this app's data model.
export 'package:zugvogel_ui/zugvogel_ui.dart'
    show FormSheetState, SheetScaffold, trimToNull;

/// The org guard every write in this app runs first.
///
/// An extension on the library's mixin rather than a mixin of our own, so no
/// sheet has to name two: the method resolves on [FormSheetState] exactly as if
/// it lived inside it.
///
/// It exists because every collection's create rule pins `org` to the caller's
/// own — that is the one write in the schema that could cross tenancy. A sheet
/// that sent no org would get a 400 with nothing useful in it; failing here
/// gives the user the app's ordinary error copy instead.
extension FormSheetOrgGuard<T extends ConsumerStatefulWidget>
    on FormSheetState<T> {
  /// Resolves the signed-in user and their org, or fails with the
  /// [RepositoryException] every sheet throws before writing without one.
  Future<(AppUser user, String org)> requireUserOrg() async {
    final user = await ref.read(currentUserProvider.future);
    final org = user?.org;
    if (user == null || org == null) {
      throw const RepositoryException('no org for current user');
    }
    return (user, org);
  }
}
