import 'dart:math' as math;

import 'package:eiermann/ui/device_location.dart';
import 'package:eiermann_models/eiermann_models.dart';
import 'package:flutter/foundation.dart';

/// One suggestion for an improvised round: a building, and how far away it is.
///
/// [metres] is null for a building with no pin. Those are not dropped — a Spot
/// nobody has placed on the map is still overdue, and hiding it would make the
/// suggestion list quietly incomplete in exactly the way that loses buildings.
/// They sort last, because "how far" is the question this list answers and they
/// cannot answer it.
@immutable
class NearbySpot {
  const NearbySpot({required this.spot, this.metres});

  final SpotOverview spot;
  final double? metres;

  @override
  bool operator ==(Object other) =>
      other is NearbySpot && other.spot.id == spot.id && other.metres == metres;

  @override
  int get hashCode => Object.hash(spot.id, metres);

  @override
  String toString() => 'NearbySpot(${spot.id}, $metres)';
}

/// The ranks worth suggesting on an improvised round.
///
/// Overdue and due-today only. Due-this-week is real work but it is not what
/// somebody standing on a street corner with twenty spare minutes is looking
/// for — padding the list with it would bury the two buildings that are
/// actually late. The other ranks are not work at all: a paused Spot is
/// deliberately out of the rhythm, and an Erkundung needs a conversation.
const Set<SpotUrgency> kNearbyRanks = {
  SpotUrgency.overdue,
  SpotUrgency.dueToday,
};

/// Overdue buildings, nearest first — the improvised round's shortlist.
///
/// **Nothing here is stored.** An ad-hoc round has no `tour_spots` rows,
/// because it has no template, and inventing some would put a route in the
/// database that nobody built and that gets walked once. So this is a
/// suggestion, the visits are the record, and the list is recomputed every time
/// it is shown.
///
/// [from] null is the ordinary case, not an error: the reader has not asked for
/// their position, or refused the permission, or is in a cellar. The list is
/// still useful — it falls back to urgency then name, which is the same order
/// every other list in this app uses — and the screen says which one it is
/// showing. Silently reordering by nothing would be worse than either.
///
/// [limit] exists because this is a shortlist and not a second Spot list: past
/// about ten entries somebody should be walking a real Tour. The cap is applied
/// AFTER sorting, so the nearest are the ones that survive it.
List<NearbySpot> overdueNearby({
  required List<SpotOverview> spots,
  LocationFix? from,
  Set<String> exclude = const {},
  int limit = 10,
}) {
  final candidates = <NearbySpot>[];
  for (final spot in spots) {
    if (exclude.contains(spot.id)) continue;
    final level = spot.level;
    // A rank this build has no name for is left out rather than guessed at: it
    // would be a suggestion nobody can justify.
    if (level == null || !kNearbyRanks.contains(level)) continue;
    final geo = spot.geo;
    candidates.add(
      NearbySpot(
        spot: spot,
        metres: from == null || geo == null
            ? null
            : distanceMetres(
                fromLat: from.lat,
                fromLon: from.lon,
                toLat: geo.lat,
                toLon: geo.lon,
              ),
      ),
    );
  }

  candidates.sort((a, b) {
    final da = a.metres;
    final db = b.metres;
    if (da != null && db != null) {
      final byDistance = da.compareTo(db);
      if (byDistance != 0) return byDistance;
    } else if (da != null) {
      return -1;
    } else if (db != null) {
      return 1;
    }
    // No distance to compare, or a dead heat: the app's ordinary order.
    final byUrgency = a.spot.urgency.compareTo(b.spot.urgency);
    return byUrgency != 0 ? byUrgency : a.spot.name.compareTo(b.spot.name);
  });

  return candidates.take(limit).toList();
}

/// Great-circle distance in metres between two coordinates.
///
/// Hand-rolled haversine rather than `Geolocator.distanceBetween`, for one
/// reason: that call is a static on a plugin, and a static cannot be stood in
/// front of in a test. The ranking above is the part worth testing, so the
/// arithmetic it depends on has to be reachable without a device.
///
/// Haversine on a sphere, not Vincenty on an ellipsoid. Over the distances this
/// list deals with — one city — the difference is a few metres in a few
/// kilometres, and the answer is only ever used to put buildings in an order.
double distanceMetres({
  required double fromLat,
  required double fromLon,
  required double toLat,
  required double toLon,
}) {
  const earthRadius = 6371000.0;
  final dLat = _radians(toLat - fromLat);
  final dLon = _radians(toLon - fromLon);
  final a =
      math.sin(dLat / 2) * math.sin(dLat / 2) +
      math.cos(_radians(fromLat)) *
          math.cos(_radians(toLat)) *
          math.sin(dLon / 2) *
          math.sin(dLon / 2);
  return earthRadius * 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a));
}

double _radians(double degrees) => degrees * math.pi / 180;
