import 'package:flutter/material.dart';
import 'package:zugvogel_ui/zugvogel_ui.dart';

/// What the router shows while it does not yet know where to send you.
///
/// Deliberately just the spinner: this is on screen for the fraction of a
/// second it takes to read the persisted server URL and session, and anything
/// more substantial would flash.
class SplashScreen extends StatelessWidget {
  const SplashScreen({super.key});

  @override
  Widget build(BuildContext context) => const Scaffold(body: LoadingView());
}
