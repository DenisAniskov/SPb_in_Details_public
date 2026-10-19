import 'package:flutter/material.dart';
import 'package:smart_navigator_spb/data/models/pedestrian_route_model.dart';

/// Distinct icons for verified native maneuver kinds. Used only in
/// NATIVE_MANEUVER_GUIDANCE presentation: fallback guidance never displays a
/// directional turn icon.
IconData maneuverIcon(PedestrianManeuverKind kind) => switch (kind) {
  PedestrianManeuverKind.straight => Icons.straight,
  PedestrianManeuverKind.left => Icons.turn_left,
  PedestrianManeuverKind.right => Icons.turn_right,
  PedestrianManeuverKind.crosswalk => Icons.directions_walk,
  PedestrianManeuverKind.stairsToUnderpass => Icons.stairs,
  PedestrianManeuverKind.stairsToOverpass => Icons.stairs,
  PedestrianManeuverKind.stairs => Icons.stairs,
  PedestrianManeuverKind.stairsDown => Icons.south,
  PedestrianManeuverKind.stairsUp => Icons.north,
};
