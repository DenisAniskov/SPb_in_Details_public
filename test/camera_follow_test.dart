import 'package:flutter_test/flutter_test.dart';
import 'package:smart_navigator_spb/data/models/pedestrian_route_model.dart';
import 'package:smart_navigator_spb/ui/controllers/camera_follow_controller.dart';

/// Phase C4 Part E3/H: opt-in «Следить за мной» camera follow. Pure UI-layer
/// logic — no native MapKit objects, no GPS streams, no timers.
void main() {
  const start = GeoCoord(60.0, 30.0);
  // ~8.3 m north of start.
  const smallStep = GeoCoord(60.00007, 30.0);
  // ~28 m north of start.
  const largeStep = GeoCoord(60.00025, 30.0);

  late CameraFollowController controller;
  final moves = <GeoCoord>[];

  setUp(() {
    moves.clear();
    controller = CameraFollowController(onFollowMove: moves.add);
  });

  tearDown(() => controller.dispose());

  test('follow is opt-in and recenters immediately on start', () {
    expect(controller.following, isFalse);
    controller.start(start);
    expect(controller.following, isTrue);
    expect(moves, [start]);
  });

  test('micro-jitter below the step threshold does not animate the camera',
      () {
    controller.start(start);
    moves.clear();
    controller.onAcceptedPosition(smallStep); // ~8.3 m
    expect(moves, isEmpty);
    expect(controller.following, isTrue);
  });

  test('a real step beyond the threshold animates the camera', () {
    controller.start(start);
    moves.clear();
    controller.onAcceptedPosition(largeStep); // ~28 m
    expect(moves, [largeStep]);
  });

  test('manual camera gesture disables following until recentered', () {
    controller.start(start);
    controller.onCameraGesture();
    expect(controller.following, isFalse);
    moves.clear();
    controller.onAcceptedPosition(largeStep);
    expect(moves, isEmpty);
    // The explicit recenter re-enables and moves once.
    controller.recenter(largeStep);
    expect(controller.following, isTrue);
    expect(moves, [largeStep]);
  });

  test('non-finite accepted positions never reach the camera', () {
    controller.start(start);
    moves.clear();
    controller.onAcceptedPosition(const GeoCoord(double.nan, 30.0));
    expect(moves, isEmpty);
  });

  test('follow threshold math uses the route distance basis', () {
    expect(followStepMeters(start, smallStep), closeTo(7.78, 0.05));
    expect(followStepMeters(start, largeStep), closeTo(27.8, 0.05));
  });
}
