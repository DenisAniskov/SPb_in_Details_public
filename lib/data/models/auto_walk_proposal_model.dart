import 'package:smart_navigator_spb/data/models/place_model.dart';
import 'package:smart_navigator_spb/data/models/smart_walk_preset.dart';

class ProposedWalkItemModel {
  final PlaceModel place;
  final int visitDurationMinutes;
  final List<String> reasons;

  const ProposedWalkItemModel({
    required this.place,
    required this.visitDurationMinutes,
    required this.reasons,
  });

  factory ProposedWalkItemModel.fromJson(Map<String, dynamic> json) {
    return ProposedWalkItemModel(
      place: PlaceModel.fromJson(json['place'] as Map<String, dynamic>),
      visitDurationMinutes: json['visit_duration_minutes'] as int? ?? 30,
      reasons:
          (json['reasons'] as List<dynamic>?)
              ?.map((e) => e.toString())
              .toList() ??
          [],
    );
  }
}

class AutoWalkProposalResponseModel {
  final String status;
  final String message;
  final int timeBudgetMinutes;
  final int estimatedWalkingDurationSeconds;
  final int estimatedVisitDurationMinutes;
  final int estimatedTotalDurationMinutes;
  final double estimatedTotalDistanceMeters;
  final List<int> suggestedPlacesSequence;
  final List<ProposedWalkItemModel> items;
  final String? reasonCode;
  final List<AutoWalkAlternativeModel> alternatives;

  const AutoWalkProposalResponseModel({
    required this.status,
    required this.message,
    required this.timeBudgetMinutes,
    required this.estimatedWalkingDurationSeconds,
    required this.estimatedVisitDurationMinutes,
    required this.estimatedTotalDurationMinutes,
    required this.estimatedTotalDistanceMeters,
    required this.suggestedPlacesSequence,
    required this.items,
    this.reasonCode,
    this.alternatives = const [],
  });

  factory AutoWalkProposalResponseModel.fromJson(Map<String, dynamic> json) {
    return AutoWalkProposalResponseModel(
      status: json['status'] as String? ?? 'success',
      reasonCode: json['reason_code'] as String?,
      alternatives:
          (json['alternatives'] as List<dynamic>?)
              ?.map(
                (e) => AutoWalkAlternativeModel.fromJson(
                  e as Map<String, dynamic>,
                ),
              )
              .toList() ??
          const [],
      message: json['message'] as String? ?? '',
      timeBudgetMinutes:
          json['time_budget_minutes'] as int? ??
          SmartWalkPreset.defaultPreset.timeBudgetMinutes,
      estimatedWalkingDurationSeconds:
          json['estimated_walking_duration_seconds'] as int? ?? 0,
      estimatedVisitDurationMinutes:
          json['estimated_visit_duration_minutes'] as int? ?? 0,
      estimatedTotalDurationMinutes:
          json['estimated_total_duration_minutes'] as int? ?? 0,
      estimatedTotalDistanceMeters:
          (json['estimated_total_distance_meters'] as num?)?.toDouble() ?? 0.0,
      suggestedPlacesSequence:
          (json['suggested_places_sequence'] as List<dynamic>?)
              ?.map((e) => e as int)
              .toList() ??
          [],
      items:
          (json['items'] as List<dynamic>?)
              ?.map(
                (e) =>
                    ProposedWalkItemModel.fromJson(e as Map<String, dynamic>),
              )
              .toList() ??
          [],
    );
  }

  String get resultMessage {
    if (items.isNotEmpty) return message;
    return switch (reasonCode) {
      'no_eligible_places' => 'В каталоге пока нет подходящих мест. Выберите другую точку отправления.',
      'category_filter_empty' =>
        'В каталоге нет мест по выбранным интересам. Измените категории.',
      'preliminary_budget_infeasible' => 'По предварительной оценке места с осмотром не помещаются в выбранное время. Измените точку отправления или выберите прогулку подольше.',
      'no_meaningful_route' => 'Подходящие места находятся у самой точки отправления. Выберите другой старт для прогулки.',
      _ => message,
    };
  }
}

/// Optional v2 candidate; older servers omit the alternatives array.
class AutoWalkAlternativeModel {
  final int timeBudgetMinutes;
  final List<int> suggestedPlacesSequence;
  final List<ProposedWalkItemModel> items;
  const AutoWalkAlternativeModel({
    required this.timeBudgetMinutes,
    required this.suggestedPlacesSequence,
    required this.items,
  });

  factory AutoWalkAlternativeModel.fromJson(Map<String, dynamic> json) =>
      AutoWalkAlternativeModel(
        timeBudgetMinutes: json['time_budget_minutes'] as int,
        suggestedPlacesSequence:
            (json['suggested_places_sequence'] as List<dynamic>)
                .map((e) => e as int)
                .toList(),
        items: (json['items'] as List<dynamic>)
            .map(
              (e) => ProposedWalkItemModel.fromJson(e as Map<String, dynamic>),
            )
            .toList(),
      );
}
