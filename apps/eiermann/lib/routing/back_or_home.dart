import 'package:eiermann/routing/router.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

/// Leaves a screen that sits OVER the nav shell — the profile, the management
/// hub, the Erkundung funnel, the figures.
///
/// Those are top-level routes with no parent page of their own, so their back
/// stack can be empty: a cold open (a shared link, a web reload, an Android
/// process restore) has nothing beneath them, and neither does an arrival by
/// `go` from a shell branch. `AppBar`'s implied leading silently disappears in
/// exactly that case, which is what strands a reader on a screen with no way
/// back. So this pops when it can and lands on the dashboard when it cannot.
///
/// Resolved through [GoRouter.maybeOf] so a screen using it still pumps in a
/// widget test that mounts it without a router.
void backOrHome(BuildContext context) {
  final router = GoRouter.maybeOf(context);
  if (router == null) return;
  if (router.canPop()) {
    router.pop();
  } else {
    router.go(Routes.dashboard);
  }
}

/// App-bar back arrow that calls [backOrHome]. Use it instead of relying on
/// `AppBar`'s implied leading, which is absent precisely when it is needed.
class BackOrHomeButton extends StatelessWidget {
  const BackOrHomeButton({super.key});

  @override
  Widget build(BuildContext context) =>
      BackButton(onPressed: () => backOrHome(context));
}

/// Applies the same fallback to the SYSTEM back gesture — the Android button, a
/// browser back on an empty stack — which would otherwise leave the app
/// entirely from a cold-opened overlay route.
class BackOrHomeScope extends StatelessWidget {
  const BackOrHomeScope({required this.child, super.key});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final router = GoRouter.maybeOf(context);
    return PopScope(
      canPop: router?.canPop() ?? false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) router?.go(Routes.dashboard);
      },
      child: child,
    );
  }
}
