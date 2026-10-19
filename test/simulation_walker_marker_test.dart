import 'package:flutter_test/flutter_test.dart';
import 'package:smart_navigator_spb/ui/screens/main_map_screen.dart';

/// Phase C4.1 follow-up: the labeled virtual-walker map marker. The pure
/// decision helpers are unit-tested here; the native placemark rendering
/// itself is device-checklist territory (native map objects cannot be
/// constructed in pure Dart tests).
void main() {
  group('showSimulatedWalkerMarker', () {
    test('shows only with the gate on, an active session and a position',
        () {
      expect(
        showSimulatedWalkerMarker(
          simulatorEnabled: true,
          navigationSessionActive: true,
          hasProjectedPosition: true,
        ),
        isTrue,
      );
    });

    test('never shows outside simulator builds', () {
      expect(
        showSimulatedWalkerMarker(
          simulatorEnabled: false,
          navigationSessionActive: true,
          hasProjectedPosition: true,
        ),
        isFalse,
      );
    });

    test('requires an active session', () {
      expect(
        showSimulatedWalkerMarker(
          simulatorEnabled: true,
          navigationSessionActive: false,
          hasProjectedPosition: true,
        ),
        isFalse,
      );
    });

    test('waits for the first accepted projected position', () {
      expect(
        showSimulatedWalkerMarker(
          simulatorEnabled: true,
          navigationSessionActive: true,
          hasProjectedPosition: false,
        ),
        isFalse,
      );
    });
  });

  test('the badge is explicitly labeled as a simulation', () {
    expect(simulatedWalkerLabel, 'Симуляция');
  });
}
