import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:smart_navigator_spb/providers/guest_experience_provider.dart';
import 'package:smart_navigator_spb/providers/navigation_provider.dart';
import 'package:smart_navigator_spb/ui/screens/guest_onboarding_screen.dart';

/// One-shot first-launch intent. The map consumes it after its first frame;
/// it is deliberately transient and is never persisted with guest settings.
class GuestLaunchIntent extends InheritedWidget {
  const GuestLaunchIntent({
    super.key,
    required this.smartWalk,
    required this.onConsumed,
    required super.child,
  });

  final bool smartWalk;
  final VoidCallback onConsumed;

  static GuestLaunchIntent? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<GuestLaunchIntent>();

  @override
  bool updateShouldNotify(GuestLaunchIntent oldWidget) =>
      smartWalk != oldWidget.smartWalk;
}

/// Defers construction of the map (and its location work) until local startup
/// has finished and the guest has left the introduction.
class GuestLaunchGate extends StatefulWidget {
  const GuestLaunchGate({super.key, required this.homeBuilder});

  final WidgetBuilder homeBuilder;

  @override
  State<GuestLaunchGate> createState() => _GuestLaunchGateState();
}

class _GuestLaunchGateState extends State<GuestLaunchGate> {
  bool _smartWalkPending = false;

  void _requestSmartWalk() {
    if (_smartWalkPending) return;
    setState(() => _smartWalkPending = true);
  }

  void _consumeSmartWalk() {
    if (!_smartWalkPending) return;
    setState(() => _smartWalkPending = false);
  }

  @override
  Widget build(BuildContext context) {
    final guest = context.watch<GuestExperienceProvider>();
    final navigation = context.watch<NavigationProvider?>();
    // A restored or already running navigation session always keeps its UI.
    if (navigation?.locksPlanning ?? false) return widget.homeBuilder(context);
    if (!guest.ready) {
      return const Scaffold(
        body: Center(
          child: CircularProgressIndicator(semanticsLabel: 'Загрузка настроек'),
        ),
      );
    }
    if (!guest.onboardingCompleted) {
      return GuestOnboardingScreen(
        firstLaunch: true,
        onStartWalk: _requestSmartWalk,
      );
    }
    final home = widget.homeBuilder(context);
    if (!_smartWalkPending) return home;
    return GuestLaunchIntent(
      smartWalk: true,
      onConsumed: _consumeSmartWalk,
      child: home,
    );
  }
}
