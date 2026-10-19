#!/usr/bin/env python3
"""Phase C5 geographic evaluation (§11) — reproducible, dataset-level.

For each frozen C2 scenario start in the five scenic target districts this
script measures, purely geometrically (Haversine, explicitly NOT a MapKit
native metric):

  - how many verified dataset features fall inside the scenic corridor of a
    synthetic ~600 m stage from the start (candidate pre-filter counts);
  - the nearest verified feature distance;
  - dataset coverage per district.

No MapKit requests are made here; the native-level metrics (real walking
time deltas, real route geometry) are device-checked separately and are
NOT_TESTED in this phase. The output is geographic_evaluation.json.
"""

from __future__ import annotations

import json
import math
from datetime import date
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
DATASET = ROOT / "lib" / "data" / "scenic" / "scenic_dataset.dart"
STARTS = ROOT / "data" / "provenance" / "phase_c2" / "phase_c2_test_starts.json"
OUT = Path(__file__).resolve().parent / "geographic_evaluation.json"

TARGET_DISTRICTS = {
    "Центральный район": "central",
    "Петроградский район": "petrogradsky",
    "Василеостровский район": "vasileostrovsky",
    "Невский район": "nevsky",
    "Приморский район": "primorsky",
}

CORRIDOR_METERS = 400
MIN_SEPARATION_METERS = 150
STAGE_LENGTH_METERS = 600


def haversine(a, b) -> float:
    lat1, lon1, lat2, lon2 = map(math.radians, (a[0], a[1], b[0], b[1]))
    dlat, dlon = lat2 - lat1, lon2 - lon1
    h = (
        math.sin(dlat / 2) ** 2
        + math.cos(lat1) * math.cos(lat2) * math.sin(dlon / 2) ** 2
    )
    return 6371000 * 2 * math.asin(math.sqrt(min(1.0, h)))


def parse_dataset() -> list[dict]:
    """Extract feature waypoints from the generated Dart dataset."""
    src = DATASET.read_text(encoding="utf-8")
    features = []
    import re

    blocks = re.findall(
        r"ScenicFeature\(\s*(.*?)\n  \),", src, flags=re.S
    )
    for block in blocks:
        get = lambda key: re.search(rf"{key}: '([^']*)'", block)
        lat = re.search(r"waypoint: GeoCoord\(([0-9.\-]+), ([0-9.\-]+)\)", block)
        ftype = re.search(r"type: ScenicFeatureType\.(\w+)", block)
        if not lat or not get("id") or not ftype:
            continue
        features.append(
            {
                "id": get("id").group(1),
                "type": ftype.group(1),
                "name": get("name").group(1),
                "district": get("district").group(1),
                "waypoint": (float(lat.group(1)), float(lat.group(2))),
            }
        )
    return features


def bearing_offset(start, length_meters, bearing_degrees) -> tuple[float, float]:
    """Synthetic stage endpoint [length_meters] away at [bearing_degrees]
    (0 = north). The evaluation is corridor counting, not routing."""
    rad = math.radians(bearing_degrees)
    dlat = length_meters * math.cos(rad) / 111194.93
    dlon = length_meters * math.sin(rad) / (
        111194.93 * math.cos(math.radians(start[0]))
    )
    return (start[0] + dlat, start[1] + dlon)


def point_to_segment_distance(p, a, b) -> float:
    lat_ref = a[0]
    kx = 111194.93 * math.cos(math.radians(lat_ref))
    ky = 111194.93
    px, py = (p[1] - a[1]) * kx, (p[0] - a[0]) * ky
    ax, ay = 0.0, 0.0
    bx, by = (b[1] - a[1]) * kx, (b[0] - a[0]) * ky
    dx, dy = bx - ax, by - ay
    length_sq = dx * dx + dy * dy
    t = 0.0 if length_sq <= 1e-9 else max(0.0, min(1.0, (px * dx + py * dy) / length_sq))
    return math.hypot(px - (ax + t * dx), py - (ay + t * dy))


def main() -> int:
    features = parse_dataset()
    starts_doc = json.loads(STARTS.read_text(encoding="utf-8"))
    scenarios = []
    for start in starts_doc["starts"]:
        district = start.get("district")
        if district not in TARGET_DISTRICTS:
            continue
        start_point = (start["lat"], start["lon"])
        nearest = math.inf
        for feature in features:
            if feature["district"] != TARGET_DISTRICTS[district]:
                continue
            nearest = min(
                nearest, haversine(start_point, feature["waypoint"])
            )
        # Probe 8 deterministic directions; report the best direction.
        direction_results = []
        best_candidates: list[dict] = []
        for bearing in range(0, 360, 45):
            end_point = bearing_offset(start_point, STAGE_LENGTH_METERS, bearing)
            corridor = []
            for feature in features:
                if feature["district"] != TARGET_DISTRICTS[district]:
                    continue
                d = haversine(start_point, feature["waypoint"])
                if d < MIN_SEPARATION_METERS:
                    continue
                if d > haversine(start_point, end_point) + MIN_SEPARATION_METERS:
                    continue
                cross = point_to_segment_distance(
                    feature["waypoint"], start_point, end_point
                )
                if cross <= CORRIDOR_METERS:
                    corridor.append(
                        {
                            "id": feature["id"],
                            "type": feature["type"],
                            "name": feature["name"],
                            "crossTrackMeters": round(cross, 1),
                        }
                    )
            corridor.sort(key=lambda c: (c["crossTrackMeters"], c["id"]))
            direction_results.append(len(corridor))
            if len(corridor) > len(best_candidates):
                best_candidates = corridor
        scenarios.append(
            {
                "startId": start["id"],
                "district": district,
                "start": {"lat": start["lat"], "lon": start["lon"]},
                "syntheticStageMeters": STAGE_LENGTH_METERS,
                "probeDirections": 8,
                "directionCandidateCounts": direction_results,
                "corridorCandidates": len(best_candidates),
                "nearestFeatureMeters": (
                    round(nearest, 1) if math.isfinite(nearest) else None
                ),
                "topCandidates": best_candidates[:5],
            }
        )

    per_district = {}
    for key in TARGET_DISTRICTS.values():
        district_features = [f for f in features if f["district"] == key]
        per_district[key] = {
            "features": len(district_features),
            "byType": {
                t: len([f for f in district_features if f["type"] == t])
                for t in ("embankment", "pedestrianStreet", "square")
            },
        }

    starts_in_targets = [s for s in scenarios]
    with_candidates = [s for s in starts_in_targets if s["corridorCandidates"] > 0]
    result = {
        "generatedOn": date.today().isoformat(),
        "datasetVersion": "2026.10.11+1",
        "method": {
            "level": "geometric pre-filter (Haversine corridor counting)",
            "disclaimer": "NOT a MapKit-native metric; real pedestrian "
            "routing results and time deltas are device-checked separately "
            "and were NOT_TESTED in this phase.",
            "corridorMeters": CORRIDOR_METERS,
            "minSeparationMeters": MIN_SEPARATION_METERS,
            "syntheticStageMeters": STAGE_LENGTH_METERS,
        },
        "datasetCoverage": per_district,
        "scenarios": scenarios,
        "summary": {
            "scenariosEvaluated": len(scenarios),
            "scenariosWithCorridorCandidates": len(with_candidates),
            "shareWithCandidates": (
                round(len(with_candidates) / len(scenarios), 3)
                if scenarios
                else 0
            ),
            "note": "A scenario counts as covered when at least one of the 8 "
            "deterministic 600 m probe directions has corridor candidates.",
            "medianCandidates": (
                sorted(s["corridorCandidates"] for s in scenarios)[
                    len(scenarios) // 2
                ]
                if scenarios
                else 0
            ),
        },
    }
    OUT.write_text(
        json.dumps(result, ensure_ascii=False, indent=1), encoding="utf-8"
    )
    print(json.dumps(result["summary"], ensure_ascii=False))
    print(json.dumps(result["datasetCoverage"], ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
