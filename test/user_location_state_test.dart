import 'package:flutter_test/flutter_test.dart';
import 'package:smart_navigator_spb/data/models/pedestrian_route_model.dart';
import 'package:smart_navigator_spb/data/models/user_location_state.dart';

/// Locks the injected-clock contract behind [UserLocationSnapshot.isFresh]:
/// freshness must follow the overridable clock so navigation tests can
/// simulate staleness without real sleeps.
void main() {
  tearDown(() => UserLocationSnapshot.clock = DateTime.now);

  UserLocationSnapshot fixAt(DateTime timestamp) => UserLocationSnapshot(
    coordinate: const GeoCoord(60, 30),
    timestamp: timestamp,
  );

  test('freshness follows the injected clock, not real time', () {
    final base = DateTime(2026);
    UserLocationSnapshot.clock = () => base;
    final fix = fixAt(base.subtract(const Duration(seconds: 14)));
    expect(fix.isFresh(maxAge: const Duration(seconds: 15)), isTrue);
    UserLocationSnapshot.clock = () => base.add(const Duration(seconds: 2));
    expect(fix.isFresh(maxAge: const Duration(seconds: 15)), isFalse);
  });

  test('future timestamps and the default one-minute window are honoured', () {
    final base = DateTime(2026);
    UserLocationSnapshot.clock = () => base;
    expect(fixAt(base.add(const Duration(seconds: 1))).isFresh(), isFalse);
    expect(fixAt(base.subtract(const Duration(minutes: 1))).isFresh(), isTrue);
    expect(
      fixAt(base.subtract(const Duration(minutes: 2))).isFresh(),
      isFalse,
    );
  });
}
