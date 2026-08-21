import 'package:geolocator/geolocator.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'device_location.g.dart';

/// A position from the device, as the map needs it.
typedef LocationFix = ({double lat, double lon});

/// Why a position could not be had.
///
/// Named cases rather than one failure, because the reader's next move differs
/// in each: a service that is off is turned on, a denied permission is granted
/// again, and a permanently denied one can only be changed in the system
/// settings — an app that said "location unavailable" to all three would send
/// somebody looking in the wrong place.
enum LocationRefusal {
  /// Location services are switched off on the device.
  serviceOff,

  /// The permission was refused for this request.
  denied,

  /// Refused permanently: on Android the "don't ask again" case, on the web a
  /// site whose permission was blocked. Only the system settings can undo it,
  /// so asking again is not the offer to make.
  deniedForever,

  /// Asked, permitted, and no fix arrived — no sky indoors, or a timeout.
  unavailable,
}

/// A position could not be determined; [reason] says what to offer instead.
class LocationUnavailable implements Exception {
  const LocationUnavailable(this.reason);

  final LocationRefusal reason;

  @override
  String toString() => 'LocationUnavailable(${reason.name})';
}

/// The device's position, behind a seam.
///
/// A class around static plugin calls, for one reason: `Geolocator`'s API is
/// static, and a test cannot stand in front of a static. Everything that asks
/// for a position goes through [deviceLocationProvider], which a widget test
/// overrides — the same shape as `imagePickerProvider`. Without it the only way
/// to test the refusal paths would be to deny a real permission on a real
/// device, which is to say: they would not be tested.
class DeviceLocation {
  const DeviceLocation();

  /// A single fix, or a [LocationUnavailable] naming why not.
  ///
  /// The service check comes first because the permission prompt is pointless
  /// without it: on a phone with location switched off, granting the permission
  /// still yields nothing, and the reader has answered a dialog for no reason.
  ///
  /// [timeLimit] exists because indoors this call can otherwise wait forever —
  /// and this app is used in stairwells and attics, which is exactly where it
  /// would. Twelve seconds is long enough for a warm fix and short enough that
  /// somebody standing in a doorway does not conclude the button is broken.
  Future<LocationFix> current({
    Duration timeLimit = const Duration(seconds: 12),
  }) async {
    if (!await Geolocator.isLocationServiceEnabled()) {
      throw const LocationUnavailable(LocationRefusal.serviceOff);
    }

    var permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }
    if (permission == LocationPermission.deniedForever) {
      throw const LocationUnavailable(LocationRefusal.deniedForever);
    }
    if (permission == LocationPermission.denied ||
        permission == LocationPermission.unableToDetermine) {
      throw const LocationUnavailable(LocationRefusal.denied);
    }

    try {
      final position = await Geolocator.getCurrentPosition(
        locationSettings: LocationSettings(timeLimit: timeLimit),
      );
      return (lat: position.latitude, lon: position.longitude);
    } on Object {
      // Every remaining failure is the same offer to the reader: try again, or
      // find the building by name. The plugin's exception types differ per
      // platform and none of them changes what to do next.
      throw const LocationUnavailable(LocationRefusal.unavailable);
    }
  }
}

/// The seam. Overridden in tests; never constructed directly by a screen.
@riverpod
DeviceLocation deviceLocation(Ref ref) => const DeviceLocation();
