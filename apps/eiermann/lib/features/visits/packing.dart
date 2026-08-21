import 'dart:math';

import 'package:eiermann_models/eiermann_models.dart';

/// How many eggs a city-pigeon clutch runs to.
///
/// Two, and it is the number the packing count is built on: you want to be able
/// to replace whatever you find, and what you can find in one nest is a full
/// clutch. Not read from `organisations.settings` on purpose — that JSON field
/// has exactly one reader, the server's `zv_org.js`, and mapping it a second
/// time in the client is the trap that silently disabled federfall's
/// org-configurable windows. If a group ever needs a different number, it
/// becomes a setting AND a server-side derivation, not a second reader here.
const int kTypicalClutchSize = 2;

/// How many Attrappen to pack for one building — the concept's "smallest
/// feature with the highest everyday value".
///
/// It replaces guessing at the car, and it is computed from the Ist-Gelege
/// rather than from history: per nest, enough dummies to fill a clutch that is
/// not already full of them. Worked through the concept's own example —
/// N1 two dummies, N2 empty, N3 one dummy and one real egg, N4 a jackdaw —
/// that is 0 + 2 + 1 + 0 = **3 Attrappen**, which is the number on the drawing.
///
/// Two exclusions, both about not sending somebody up a ladder for nothing:
/// a [NestStatus.gone] nest has nowhere to put an egg, and a protected one may
/// not be touched at all — every egg mutation on it is refused server-side.
///
/// It is an upper bound and not a forecast: what the birds laid overnight is
/// not knowable, which is why the line beside it says the count is the current
/// clutch. Over-packing costs nothing; the number exists so nobody drives back.
int dummiesToPack(Iterable<NestState> nests) => nests.fold(0, (sum, nest) {
  if (nest.isGone || nest.isProtected) return sum;
  return sum + max(0, kTypicalClutchSize - nest.dummyCount);
});
