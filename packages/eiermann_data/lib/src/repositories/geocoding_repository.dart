import 'dart:async';

import 'package:pocketbase/pocketbase.dart';
import 'package:zugvogel_core/zugvogel_core.dart';
import 'package:zugvogel_data/zugvogel_data.dart';

/// One geocoding candidate: a pin, and the address the geocoder resolved for
/// it.
class GeoResult {
  const GeoResult({
    required this.lat,
    required this.lon,
    this.displayName = '',
    this.city = '',
    this.region = '',
  });

  /// Parses one entry of the proxy's JSON, or null when it is not a map or has
  /// no numeric coordinates.
  ///
  /// Skipping beats defaulting. Behind the proxy sits a third-party geocoder,
  /// and a malformed entry defaulted to (0, 0) is a plausible-looking pin in
  /// the Gulf of Guinea that somebody could save onto a building in Oldenburg
  /// — after which `GeoPoint.fromPb` reads it back as "no pin at all" and the
  /// wrong-door problem is invisible in the data.
  static GeoResult? tryParse(Object? raw) {
    if (raw is! Map<String, dynamic>) return null;
    final lat = raw['lat'];
    final lon = raw['lon'];
    if (lat is! num || lon is! num) return null;
    return GeoResult(
      lat: lat.toDouble(),
      lon: lon.toDouble(),
      displayName: (raw['displayName'] as String?) ?? '',
      city: (raw['city'] as String?) ?? '',
      region: (raw['region'] as String?) ?? '',
    );
  }

  final double lat;
  final double lon;

  /// A tidy "Straße 8, 26125 Ort", composed server-side. Falls back to the
  /// geocoder's own long form when the parts are missing.
  final String displayName;
  final String city;
  final String region;

  /// The candidate as the app's own geo type.
  GeoPoint get point => GeoPoint(lat: lat, lon: lon);

  /// The street line out of [displayName], or null when it cannot be told
  /// apart from the rest.
  ///
  /// [displayName] is composed by our OWN proxy, not by the geocoder, and the
  /// recipe is short enough to invert: `zv_geocode.js` builds
  /// `"<road> <house_number>, <postcode> <city>"`, dropping whichever parts the
  /// upstream did not supply. So it has at most TWO comma-separated segments,
  /// and that is the check — anything with more is the geocoder's own long
  /// `display_name`, which the proxy falls back to when there was no road at
  /// all. Those are not parsed: "3, Nachbarhaus, Innenstadt, Oldenburg,
  /// Niedersachsen, 26122, Deutschland" has a house number where a street
  /// should be, and half an address in a form field looks like something a
  /// person typed.
  ///
  /// The postcode and street are not returned by the proxy as separate fields
  /// (only `city` is), which is why this exists at all. Adding them upstream
  /// would be the better fix and needs a new zugvogel-pb-base image —
  /// eiermann-8ak.
  String? get street {
    final parts = _ownParts;
    if (parts == null) return null;
    final street = parts.$1;
    return street.isEmpty ? null : street;
  }

  /// The postcode out of [displayName], or null when there is none to read.
  String? get postalCode {
    final parts = _ownParts;
    if (parts == null) return null;
    final code = parts.$2;
    return code.isEmpty ? null : code;
  }

  /// `(street, postcode)` when [displayName] has the shape our proxy composes,
  /// null otherwise.
  (String, String)? get _ownParts {
    final segments = displayName
        .split(',')
        .map((part) => part.trim())
        .where((part) => part.isNotEmpty)
        .toList();
    // Our composer emits one or two segments. More means the fallback form.
    if (segments.isEmpty || segments.length > 2) return null;

    // Which segment is the locality half: the one carrying the city, or — when
    // the upstream gave no city — a bare postcode.
    final localityAt = city.isEmpty
        ? segments.lastIndexWhere(_postcode.hasMatch)
        : segments.lastIndexWhere((s) => s.endsWith(city));
    if (localityAt < 0) {
      // No locality half at all, so the whole thing is the street:
      // `[street, locality]` with an empty locality is just the street.
      return (segments.join(', '), '');
    }

    final locality = segments[localityAt];
    final code = city.isEmpty
        ? locality
        : locality.substring(0, locality.length - city.length).trim();
    return (
      segments.take(localityAt).join(', '),
      _postcode.hasMatch(code) ? code : '',
    );
  }

  /// Four or five digits, which covers German postcodes and the neighbours'
  /// without matching a house number.
  static final _postcode = RegExp(r'^\d{4,5}$');
}

/// Address ⇄ coordinate lookups, through eiermann's own backend.
///
/// Never a direct call to a geocoder, for three reasons that are all the
/// server's job: the upstream needs a real contact in its User-Agent and a
/// per-deployment URL an operator sets, the rate limit has to be enforced
/// somewhere a client cannot bypass, and a browser cannot call Nominatim at all
/// — no CORS headers. The proxy also caches, so twenty volunteers looking up
/// the same street cost one upstream request.
///
/// Failures arrive as [RepositoryException] like every other read, so the
/// screens can use the same error copy. Two are worth telling apart: an
/// unreachable *server* is `network`, and an unreachable *geocoder* is the
/// proxy's 502, which lands as `unknown` — the address entry still works, only
/// the coordinate lookup is out.
abstract interface class GeocodingRepository {
  /// Forward: free text → candidates, best first, at most five (the proxy's
  /// limit).
  Future<List<GeoResult>> forward(String query);

  /// Reverse: a pin → its address, or null when the geocoder resolved nothing.
  Future<GeoResult?> reverse(double lat, double lon);
}

/// [GeocodingRepository] over the routes in `geocode.pb.js`.
class PbGeocodingRepository implements GeocodingRepository {
  PbGeocodingRepository(
    this.pb, {
    this.networkTimeout = const Duration(seconds: 15),
  });

  final PocketBase pb;

  /// Caps one request so an unreachable server fails fast instead of hanging
  /// on the OS TCP timeout. Longer than a collection read on purpose: this one
  /// may be waiting on a third party behind the proxy.
  final Duration networkTimeout;

  @override
  Future<List<GeoResult>> forward(String query) => _guard(() async {
    final res = await pb.send<Map<String, dynamic>>(
      '/api/eiermann/geocode',
      query: {'q': query},
    );
    final results = (res['results'] as List?) ?? const [];
    return results.map(GeoResult.tryParse).whereType<GeoResult>().toList();
  });

  @override
  Future<GeoResult?> reverse(double lat, double lon) => _guard(() async {
    final res = await pb.send<Map<String, dynamic>>(
      '/api/eiermann/geocode/reverse',
      query: {'lat': '$lat', 'lon': '$lon'},
    );
    // A malformed result reads as "unresolved", which is the same thing to the
    // caller as a pin in the North Sea: there is no address to offer.
    return GeoResult.tryParse(res['result']);
  });

  /// The same classification `PbRepository.guard` applies, for a call that is
  /// not against a collection.
  ///
  /// Duplicated rather than reused because `guard` hangs off
  /// `PbReadOnlyRepository`, whose contract is a collection name and a record
  /// mapper — neither of which a route has. There is no `write: true` case
  /// here: both routes are GETs, so a timeout is unambiguously "not reached"
  /// and never the `unknownOutcome` a half-committed write needs.
  ///
  /// federfall has the same function for the same reason. The third copy is
  /// where it goes into zugvogel — see eiermann-a0v.
  Future<R> _guard<R>(Future<R> Function() op) async {
    try {
      return await op().timeout(networkTimeout);
    } on TimeoutException {
      throw const RepositoryException(
        'Could not reach the server',
        kind: RepositoryErrorKind.network,
      );
    } on ClientException catch (e) {
      throw RepositoryException.fromClient(e);
    } on RepositoryException {
      rethrow;
    } on Object catch (e) {
      throw RepositoryException('Unexpected repository failure: $e', cause: e);
    }
  }
}
