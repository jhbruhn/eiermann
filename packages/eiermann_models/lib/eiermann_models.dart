/// Immutable domain models for Eiermann, plus the PocketBase mappers.
///
/// Every enum carries the exact string PocketBase stores (see `WireEnum` in
/// zugvogel_core), so renaming a Dart identifier cannot change what is written
/// to the database and snake_case never leaks out of the mapping layer.
library;

export 'src/enums.dart';
export 'src/models/app_user.dart';
export 'src/models/area.dart';
export 'src/models/finding.dart';
export 'src/models/finding_draft.dart';
export 'src/models/follow_up.dart';
export 'src/models/nest.dart';
export 'src/models/nest_check.dart';
export 'src/models/nest_check_draft.dart';
export 'src/models/nest_egg.dart';
export 'src/models/nest_state.dart';
export 'src/models/org_statistics.dart';
export 'src/models/organisation.dart';
export 'src/models/rhythm_settings.dart';
export 'src/models/species_label.dart';
export 'src/models/spot.dart';
export 'src/models/spot_contact.dart';
export 'src/models/spot_overview.dart';
export 'src/models/tour.dart';
export 'src/models/visit.dart';
export 'src/models/visit_draft.dart';
export 'src/spot_transitions.dart';
export 'src/tour_progress.dart';
