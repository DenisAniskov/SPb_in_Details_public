import 'package:smart_navigator_spb/data/models/place_model.dart';

/// A real catalog row confirmed by the backend. The model never supplies IDs.
class AssistantPlaceReference {
  const AssistantPlaceReference({
    required this.id,
    required this.catalogKey,
    required this.title,
    required this.category,
    required this.isUnusual,
    required this.shortDescription,
  });

  final int id;
  final String? catalogKey;
  final String title;
  final PlaceCategoryEnum category;
  final bool isUnusual;
  final String shortDescription;

  factory AssistantPlaceReference.fromJson(Map<String, dynamic> json) {
    final id = json['id'];
    final title = json['title'];
    final description = json['short_description'];
    final category = json['category'];
    final unusual = json['is_unusual'];
    final key = json['catalog_key'];
    if (id is! int ||
        id <= 0 ||
        title is! String ||
        title.isEmpty ||
        description is! String ||
        category is! String ||
        unusual is! bool ||
        (key != null && key is! String)) {
      throw const FormatException('Invalid assistant place reference');
    }
    return AssistantPlaceReference(
      id: id,
      catalogKey: key as String?,
      title: title,
      category: PlaceCategoryEnum.fromString(category),
      isUnusual: unusual,
      shortDescription: description,
    );
  }
}

class AssistantAction {
  const AssistantAction({required this.type, required this.label});

  final String type;
  final String label;

  bool get isOpenSmartWalk => type == 'open_smart_walk';

  factory AssistantAction.fromJson(Map<String, dynamic> json) {
    final type = json['type'];
    final label = json['label'];
    if (type is! String || type.isEmpty || label is! String || label.isEmpty) {
      throw const FormatException('Invalid assistant action');
    }
    return AssistantAction(type: type, label: label);
  }
}

class AssistantUsage {
  const AssistantUsage({
    this.promptTokens,
    this.completionTokens,
    this.costUsd,
    this.costVerified = false,
  });

  final int? promptTokens;
  final int? completionTokens;
  final double? costUsd;
  final bool costVerified;

  factory AssistantUsage.fromJson(Map<String, dynamic>? json) {
    if (json == null) return const AssistantUsage();
    final prompt = json['prompt_tokens'];
    final completion = json['completion_tokens'];
    final cost = json['cost_usd'];
    final verified = json['cost_verified'];
    if ((prompt != null && (prompt is! int || prompt < 0)) ||
        (completion != null && (completion is! int || completion < 0)) ||
        (cost != null && (cost is! num || !cost.isFinite || cost < 0)) ||
        (verified != null && verified is! bool)) {
      throw const FormatException('Invalid assistant usage');
    }
    return AssistantUsage(
      promptTokens: prompt as int?,
      completionTokens: completion as int?,
      costUsd: (cost as num?)?.toDouble(),
      costVerified: verified as bool? ?? false,
    );
  }
}

class AssistantReply {
  const AssistantReply({
    required this.status,
    required this.answer,
    required this.model,
    required this.places,
    required this.actions,
    required this.warnings,
    required this.usage,
  });

  final String status;
  final String answer;
  final String? model;
  final List<AssistantPlaceReference> places;
  final List<AssistantAction> actions;
  final List<String> warnings;
  final AssistantUsage usage;

  bool get hasAnswer => answer.trim().isNotEmpty;
  bool get openSmartWalk => actions.any((action) => action.isOpenSmartWalk);

  factory AssistantReply.fromJson(Map<String, dynamic> json) {
    final status = json['status'];
    final answer = json['answer'];
    final model = json['model'];
    if (status is! String ||
        !const {'ok', 'insufficient_data', 'unavailable'}.contains(status) ||
        answer is! String ||
        answer.trim().isEmpty ||
        answer.length > 8000 ||
        (model != null && model is! String)) {
      throw const FormatException('Invalid assistant reply');
    }
    final rawPlaces = json['places'];
    final rawActions = json['actions'];
    final rawWarnings = json['warnings'];
    if (rawPlaces is! List ||
        rawActions is! List ||
        rawWarnings is! List ||
        rawWarnings.any((value) => value is! String)) {
      throw const FormatException('Invalid assistant reply collections');
    }
    return AssistantReply(
      status: status,
      answer: answer,
      model: model as String?,
      places: List.unmodifiable(
        rawPlaces.map((value) {
          if (value is! Map<String, dynamic>) {
            throw const FormatException('Invalid assistant place');
          }
          return AssistantPlaceReference.fromJson(value);
        }),
      ),
      actions: List.unmodifiable(
        rawActions.map((value) {
          if (value is! Map<String, dynamic>) {
            throw const FormatException('Invalid assistant action');
          }
          return AssistantAction.fromJson(value);
        }),
      ),
      warnings: List.unmodifiable(rawWarnings.cast<String>()),
      usage: AssistantUsage.fromJson(
        json['usage'] is Map<String, dynamic>
            ? json['usage'] as Map<String, dynamic>
            : null,
      ),
    );
  }
}

class AssistantHistoryTurn {
  const AssistantHistoryTurn({required this.role, required this.content});

  final String role;
  final String content;

  Map<String, dynamic> toJson() => {'role': role, 'content': content};
}
