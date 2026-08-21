/// Repository layer for Eiermann: typed PocketBase-backed repositories with
/// model mapping and error translation.
///
/// The generic half — the repository base, PbFilter, keyset paging, the error
/// translation — comes from zugvogel_data. What lives here is the part that
/// knows collection names and mappers.
library;

export 'package:zugvogel_data/zugvogel_data.dart';

export 'src/repositories/areas_repository.dart';
export 'src/repositories/auth_repository.dart';
export 'src/repositories/geocoding_repository.dart';
export 'src/repositories/nest_state_repository.dart';
export 'src/repositories/nests_repository.dart';
export 'src/repositories/spot_contacts_repository.dart';
export 'src/repositories/spot_overview_repository.dart';
export 'src/repositories/spots_repository.dart';
