import 'package:flutter/foundation.dart';

/// Opt-in availability gate for the navigation simulator (Phase C4.1).
///
/// The simulator exists exclusively for debugging the live navigation engine
/// without physical movement. It is compiled into the app but activates only
/// when BOTH conditions hold:
///
/// 1. debug build (`kDebugMode` — false in release/profile), and
/// 2. an explicit build-time opt-in: `--dart-define=NAVIGATION_SIMULATOR=true`.
///
/// Neither condition can be flipped at runtime by app state, so production
/// builds and ordinary debug runs never contain an active simulator.
class NavigationSimulatorGate {
  NavigationSimulatorGate._();

  /// Test-only override; production code must never set it.
  @visibleForTesting
  static bool? overrideForTesting;

  static bool get enabled =>
      overrideForTesting ??
      (kDebugMode &&
          const bool.fromEnvironment('NAVIGATION_SIMULATOR'));
}
