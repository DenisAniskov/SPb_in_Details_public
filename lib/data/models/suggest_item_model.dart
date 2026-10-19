class SuggestItemModel {
  final String title;
  final String? subtitle;
  final List<String> tags;
  final String? uri;
  final String? distanceText;

  const SuggestItemModel({
    required this.title,
    this.subtitle,
    this.tags = const [],
    this.uri,
    this.distanceText,
  });

  factory SuggestItemModel.fromJson(Map<String, dynamic> json) {
    return SuggestItemModel(
      title: json['title'] as String? ?? '',
      subtitle: json['subtitle'] as String?,
      tags:
          (json['tags'] as List<dynamic>?)?.map((e) => e.toString()).toList() ??
          const [],
      uri: json['uri'] as String?,
      distanceText: json['distance_text'] as String?,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'title': title,
      'subtitle': subtitle,
      'tags': tags,
      'uri': uri,
      'distance_text': distanceText,
    };
  }
}
