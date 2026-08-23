import 'dart:async';

import 'package:eiermann/l10n/l10n.dart';
import 'package:eiermann/ui/device_location.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// The sentence for a refusal. Each case offers a different next move, which is
/// the whole reason [LocationRefusal] has cases at all: a service that is off
/// is turned on, a denied permission is granted again, and a permanently denied
/// one can only be changed in the system settings.
String locationRefusalMessage(AppLocalizations l10n, LocationRefusal reason) =>
    switch (reason) {
      LocationRefusal.serviceOff => l10n.spotsMapLocationServiceOff,
      LocationRefusal.denied => l10n.spotsMapLocationDenied,
      LocationRefusal.deniedForever => l10n.spotsMapLocationBlocked,
      LocationRefusal.unavailable => l10n.spotsMapLocationUnavailable,
    };

/// "Mein Standort": asks for a fix and hands it to [onFix].
///
/// One widget for both maps. It was very nearly two copies — the spot map had
/// this button and the pin picker did not — and the second copy is how the two
/// drift: a refusal case added in one place would have reached one screen only.
///
/// The button owns its busy state and its snackbar, and the caller owns the
/// camera. That split is deliberate: what to DO with a position differs (the
/// map drops a marker, the picker re-resolves the address strip), but asking
/// for one, spinning while it arrives and saying why it did not are the same
/// everywhere.
///
/// It always goes through [DeviceLocation.current], which prompts. That is
/// correct here and only here: a press IS somebody asking. Everything that
/// wants a position without being asked for one uses
/// [DeviceLocation.currentIfPermitted].
class LocateMeButton extends ConsumerStatefulWidget {
  const LocateMeButton({
    required this.onFix,
    this.heroTag = 'locate',
    super.key,
  });

  /// Called with the position once it arrives. Never called for a refusal —
  /// the snackbar handles that, because a caller has nothing to do with a
  /// position it did not get.
  final ValueChanged<LocationFix> onFix;

  /// Distinct per screen when more than one FAB is on it: Hero throws on a
  /// duplicate tag during the route transition, so the failure surfaces as a
  /// crash on navigation rather than on the screen that owns the button.
  final Object? heroTag;

  @override
  ConsumerState<LocateMeButton> createState() => _LocateMeButtonState();
}

class _LocateMeButtonState extends ConsumerState<LocateMeButton> {
  bool _busy = false;

  Future<void> _locate() async {
    final l10n = context.l10n;
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _busy = true);
    try {
      final fix = await ref.read(deviceLocationProvider).current();
      if (!mounted) return;
      widget.onFix(fix);
    } on LocationUnavailable catch (refusal) {
      messenger.showSnackBar(
        SnackBar(content: Text(locationRefusalMessage(l10n, refusal.reason))),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return FloatingActionButton.small(
      heroTag: widget.heroTag,
      onPressed: _busy ? null : () => unawaited(_locate()),
      tooltip: context.l10n.spotsMapNearMeAction,
      child: _busy
          ? const SizedBox.square(
              dimension: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : const Icon(Icons.my_location),
    );
  }
}
