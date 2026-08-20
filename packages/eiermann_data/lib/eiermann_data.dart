/// Repository layer for Eiermann: typed PocketBase-backed repositories with
/// model mapping and error translation.
///
/// The generic half — the repository base, PbFilter, keyset paging, the error
/// translation — comes from zugvogel_data. What lives here is the part that
/// knows collection names and mappers.
library;

export 'package:zugvogel_data/zugvogel_data.dart';

export 'src/repositories/auth_repository.dart';
