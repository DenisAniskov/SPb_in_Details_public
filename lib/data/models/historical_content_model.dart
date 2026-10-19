import 'package:flutter/material.dart';

/// Phase C6: structured historical content of one catalog place.
///
/// The JSON comes from the verified editorial dataset served by
/// `GET /places/{place_id}/history`. Parsing is deliberately defensive:
/// a partially damaged payload degrades to empty lists and absent optional
/// fields instead of crashing the card — the historical layer is optional
/// and must never break the place screen.
class HistoricalContent {
  final String catalogKey;
  final String locale;
  final String shortHistoricalSummary;
  final String detailedHistoricalText;

  /// Historical span of the object, e.g. «1754–1762» — free-form editorial
  /// label, never parsed into a machine date on the client.
  final String? period;
  final List<HistoricalTimelineEvent> timeline;
  final List<HistoricalPerson> people;
  final List<HistoricalFact> facts;
  final List<HistoricalSource> sources;
  final String editorialStatus;
  final String lastVerifiedOn;

  const HistoricalContent({
    required this.catalogKey,
    required this.locale,
    required this.shortHistoricalSummary,
    required this.detailedHistoricalText,
    required this.period,
    required this.timeline,
    required this.people,
    required this.facts,
    required this.sources,
    required this.editorialStatus,
    required this.lastVerifiedOn,
  });

  bool get hasTimeline => timeline.isNotEmpty;
  bool get hasFacts => facts.isNotEmpty;
  bool get hasPeople => people.isNotEmpty;
  bool get hasSources => sources.isNotEmpty;

  factory HistoricalContent.fromJson(Map<String, dynamic> json) {
    String stringOr(Object? value) => value is String ? value : '';
    return HistoricalContent(
      catalogKey: stringOr(json['catalogKey']),
      locale: json['locale'] is String ? json['locale'] as String : 'ru',
      shortHistoricalSummary: stringOr(json['short_historical_summary'] ?? json['shortHistoricalSummary']),
      detailedHistoricalText: stringOr(
        json['detailed_historical_text'] ?? json['detailedHistoricalText'],
      ),
      period: json['period'] is String ? json['period'] as String : null,
      timeline: _mapList(
        json['timeline'],
        (item) => HistoricalTimelineEvent.fromJson(item),
        (event) => event.id.isNotEmpty && event.title.isNotEmpty,
      ),
      people: _mapList(
        json['people'],
        (item) => HistoricalPerson.fromJson(item),
        (person) => person.name.isNotEmpty,
      ),
      facts: _mapList(
        json['facts'],
        (item) => HistoricalFact.fromJson(item),
        (fact) => fact.id.isNotEmpty && fact.text.isNotEmpty,
      ),
      sources: _mapList(
        json['sources'],
        (item) => HistoricalSource.fromJson(item),
        (source) => source.id.isNotEmpty && source.url.isNotEmpty,
      ),
      editorialStatus: stringOr(json['editorial_status'] ?? json['editorialStatus']),
      lastVerifiedOn: stringOr(json['last_verified_on'] ?? json['lastVerifiedOn']),
    );
  }

  static List<T> _mapList<T>(
    Object? raw,
    T Function(Map<String, dynamic>) build, [
    bool Function(T item)? keep,
  ]) {
    if (raw is! List) return const [];
    final items = [
      for (final item in raw)
        if (item is Map<String, dynamic>) build(item),
    ];
    return keep == null ? items : items.where(keep).toList();
  }

  /// Defensive list-of-strings parsing: non-string entries are dropped
  /// instead of crashing the card.
  static List<String> mapStrings(Object? raw) {
    if (raw is! List) return const [];
    return [for (final item in raw) if (item is String) item];
  }
}

/// §3.3: one dated event. `dateLabel` is displayed as written («середина
/// XVIII века» stays a period — no false precision is manufactured here).
class HistoricalTimelineEvent {
  final String id;
  final String dateLabel;
  final String datePrecision;
  final String? sortKey;
  final String title;
  final String description;

  const HistoricalTimelineEvent({
    required this.id,
    required this.dateLabel,
    required this.datePrecision,
    required this.sortKey,
    required this.title,
    required this.description,
  });

  factory HistoricalTimelineEvent.fromJson(Map<String, dynamic> json) {
    String stringOr(Object? value) => value is String ? value : '';
    return HistoricalTimelineEvent(
      id: stringOr(json['id']),
      dateLabel: stringOr(json['dateLabel'] ?? json['date_label']),
      datePrecision: stringOr(json['datePrecision'] ?? json['date_precision']),
      sortKey: json['sortKey'] is String ? json['sortKey'] as String : null,
      title: stringOr(json['title']),
      description: stringOr(json['description']),
    );
  }
}

/// §3.4: attributed person. Roles map to fixed Russian labels below.
class HistoricalPerson {
  final String name;
  final String role;
  final String? description;

  const HistoricalPerson({
    required this.name,
    required this.role,
    required this.description,
  });

  factory HistoricalPerson.fromJson(Map<String, dynamic> json) {
    return HistoricalPerson(
      name: json['name'] is String ? json['name'] as String : '',
      role: json['role'] is String ? json['role'] as String : 'other',
      description: json['description'] is String
          ? json['description'] as String
          : null,
    );
  }

  String get roleLabel => switch (role) {
        'architect' => 'архитектор',
        'engineer' => 'инженер',
        'sculptor' => 'скульптор',
        'founder' => 'основатель',
        'patron' => 'заказчик и благотворитель',
        'historical_figure' => 'историческая личность',
        _ => '',
      };
}

/// §3.2: one verifiable fact with an explicit source link.
class HistoricalFact {
  final String id;
  final String title;
  final String text;
  final String category;
  final List<String> sourceIds;

  const HistoricalFact({
    required this.id,
    required this.title,
    required this.text,
    required this.category,
    required this.sourceIds,
  });

  factory HistoricalFact.fromJson(Map<String, dynamic> json) {
    return HistoricalFact(
      id: json['id'] is String ? json['id'] as String : '',
      title: json['title'] is String ? json['title'] as String : '',
      text: json['text'] is String ? json['text'] as String : '',
      category: json['category'] is String ? json['category'] as String : '',
      sourceIds: HistoricalContent.mapStrings(json['sourceIds'] ?? json['source_ids']),
    );
  }

  String get categoryLabel => switch (category) {
        'architecture' => 'Архитектура',
        'creation_history' => 'История создания',
        'historical_events' => 'Исторические события',
        'notable_people' => 'Известные личности',
        'cultural_significance' => 'Культурное значение',
        'interesting_details' => 'Интересные особенности',
        'reconstructions' => 'Изменения и реконструкции',
        _ => '',
      };
}

/// §3.5: a verified source. The client only opens its URL externally; it
/// never fetches the page content itself.
class HistoricalSource {
  final String id;
  final String title;
  final String url;
  final String? publisher;
  final String sourceType;
  final String accessedOn;
  final String? license;
  final String? notes;

  const HistoricalSource({
    required this.id,
    required this.title,
    required this.url,
    required this.publisher,
    required this.sourceType,
    required this.accessedOn,
    required this.license,
    required this.notes,
  });

  factory HistoricalSource.fromJson(Map<String, dynamic> json) {
    String? stringOrNull(Object? value) => value is String ? value : null;
    return HistoricalSource(
      id: json['id'] is String ? json['id'] as String : '',
      title: json['title'] is String ? json['title'] as String : '',
      url: json['url'] is String ? json['url'] as String : '',
      publisher: stringOrNull(json['publisher']),
      sourceType: json['sourceType'] is String ? json['sourceType'] as String : '',
      accessedOn: stringOrNull(json['accessedOn'] ?? json['accessed_on']) ?? '',
      license: stringOrNull(json['license']),
      notes: stringOrNull(json['notes']),
    );
  }

  String get typeLabel => switch (sourceType) {
        'official_museum' => 'Официальный сайт',
        'government_heritage' => 'Государственный ресурс',
        'academic' => 'Научная публикация',
        'official_reference' => 'Официальный справочник',
        'encyclopedia' => 'Энциклопедия',
        _ => 'Источник',
      };

  IconData get icon => switch (sourceType) {
        'official_museum' => Icons.language,
        'government_heritage' => Icons.account_balance,
        'academic' => Icons.school,
        _ => Icons.menu_book,
      };
}
