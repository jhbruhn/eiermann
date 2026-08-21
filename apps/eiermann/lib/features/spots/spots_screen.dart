import 'package:eiermann/features/home/sign_out_action.dart';
import 'package:eiermann/features/spots/spot_sheet.dart';
import 'package:eiermann/features/spots/spots_list.dart';
import 'package:eiermann/l10n/l10n.dart';
import 'package:eiermann_models/eiermann_models.dart';
import 'package:flutter/material.dart';

/// The Spot list as a destination: every building the group has, most urgent
/// first.
///
/// [urgency] comes from the route's query parameter, which is where a dashboard
/// tile puts it. In the location rather than in a provider handed across
/// branches, because a filter that is part of the URL survives a state
/// restore, can be linked to on web, and is dropped by the one gesture a
/// reader will try anyway — tapping the tab again, which returns the branch to
/// its root.
class SpotsScreen extends StatelessWidget {
  const SpotsScreen({this.urgency, super.key});

  final SpotUrgency? urgency;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.spotsTitle),
        actions: const [SignOutAction()],
      ),
      body: SpotsList(urgency: urgency),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => showSpotSheet(context),
        icon: const Icon(Icons.add),
        label: Text(l10n.spotsEmptyAction),
      ),
    );
  }
}
