import 'package:flutter/material.dart';
import 'package:smart_navigator_spb/core/constants/app_colors.dart';
import 'package:smart_navigator_spb/core/constants/app_strings.dart';

enum PlaceCategoryEnum {
  historyArchitecture('history_architecture'),
  art('art'),
  scienceTechnology('science_technology'),
  nature('nature'),
  modernSpaces('modern_spaces'),
  familyLeisure('family_leisure');

  final String key;
  const PlaceCategoryEnum(this.key);

  static PlaceCategoryEnum fromString(String value) {
    return PlaceCategoryEnum.values.firstWhere(
      (e) => e.key == value || e.name == value,
    );
  }

  String get displayName {
    switch (this) {
      case PlaceCategoryEnum.historyArchitecture:
        return AppStrings.catHistoryArchitecture;
      case PlaceCategoryEnum.art:
        return AppStrings.catArt;
      case PlaceCategoryEnum.scienceTechnology:
        return AppStrings.catScienceTechnology;
      case PlaceCategoryEnum.nature:
        return AppStrings.catNature;
      case PlaceCategoryEnum.modernSpaces:
        return AppStrings.catModernSpaces;
      case PlaceCategoryEnum.familyLeisure:
        return AppStrings.catFamilyLeisure;
    }
  }

  IconData get icon {
    switch (this) {
      case PlaceCategoryEnum.historyArchitecture:
        return Icons.account_balance;
      case PlaceCategoryEnum.art:
        return Icons.palette;
      case PlaceCategoryEnum.scienceTechnology:
        return Icons.science;
      case PlaceCategoryEnum.nature:
        return Icons.park;
      case PlaceCategoryEnum.modernSpaces:
        return Icons.local_activity;
      case PlaceCategoryEnum.familyLeisure:
        return Icons.family_restroom;
    }
  }

  Color get color {
    switch (this) {
      case PlaceCategoryEnum.historyArchitecture:
        return AppColors.historyArchitecture;
      case PlaceCategoryEnum.art:
        return AppColors.art;
      case PlaceCategoryEnum.scienceTechnology:
        return AppColors.scienceTechnology;
      case PlaceCategoryEnum.nature:
        return AppColors.nature;
      case PlaceCategoryEnum.modernSpaces:
        return AppColors.modernSpaces;
      case PlaceCategoryEnum.familyLeisure:
        return AppColors.familyLeisure;
    }
  }
}

class PlaceModel {
  final int id;

  /// Stable catalog identity when supplied by the server. Database IDs alone
  /// are not portable identities across staging servers or database copies.
  final String? catalogKey;
  final String title;
  final String shortDescription;
  final String? fullDescription;
  final PlaceCategoryEnum category;
  final bool isUnusual;
  final double latitude;
  final double longitude;
  final String address;
  final String? photoUrl;
  final String? workingHours;
  final String? tags;
  final double? rating;
  final String? architecturalStyle;
  final String? yearBuilt;
  final String? sourceUrl;
  final String coordinateKind;
  final String addressStatus;
  final int recommendedVisitMinutes;
  final String? whyVisit;
  final String? visitNote;
  final String? officialWebsite;
  final String? wikipediaUrl;
  // Phase C3: display point is the published representative coordinate;
  // routing fields are filled only with a verified public entrance/approach.
  final double? routingLatitude;
  final double? routingLongitude;
  final String? routingPointSource;
  final String? routingPointVerifiedOn;
  final String routingAccessStatus;

  const PlaceModel({
    required this.id,
    this.catalogKey,
    required this.title,
    required this.shortDescription,
    this.fullDescription,
    required this.category,
    this.isUnusual = false,
    required this.latitude,
    required this.longitude,
    required this.address,
    this.photoUrl,
    this.workingHours,
    this.tags,
    this.rating,
    this.architecturalStyle,
    this.yearBuilt,
    this.sourceUrl,
    this.coordinateKind = 'unverified',
    this.addressStatus = 'unverified',
    this.recommendedVisitMinutes = 30,
    this.whyVisit,
    this.visitNote,
    this.officialWebsite,
    this.wikipediaUrl,
    this.routingLatitude,
    this.routingLongitude,
    this.routingPointSource,
    this.routingPointVerifiedOn,
    this.routingAccessStatus = 'representative_point_only',
  });

  factory PlaceModel.fromJson(Map<String, dynamic> json) {
    final visit = json['recommended_visit_minutes'] ?? 30;
    if (visit is! int || visit < 5 || visit > 180) {
      throw const FormatException('Invalid SmartNavigator visit estimate');
    }
    return PlaceModel(
      id: json['id'] as int,
      catalogKey: _validCatalogKey(json['catalog_key']),
      title: json['title'] as String,
      shortDescription: json['short_description'] as String,
      fullDescription: json['full_description'] as String?,
      category: PlaceCategoryEnum.fromString(json['category'] as String),
      isUnusual: json['is_unusual'] as bool? ?? false,
      latitude: (json['latitude'] as num).toDouble(),
      longitude: (json['longitude'] as num).toDouble(),
      address: json['address'] as String,
      photoUrl: json['photo_url'] as String?,
      workingHours: json['working_hours'] as String?,
      tags: json['tags'] as String?,
      rating: (json['rating'] as num?)?.toDouble(),
      architecturalStyle: json['architectural_style'] as String?,
      yearBuilt: json['year_built'] as String?,
      sourceUrl: json['source_url'] as String?,
      coordinateKind: json['coordinate_kind'] as String? ?? 'unverified',
      addressStatus: json['address_status'] as String? ?? 'unverified',
      recommendedVisitMinutes: visit,
      whyVisit: json['why_visit'] as String?,
      visitNote: json['visit_note'] as String?,
      officialWebsite: json['official_website'] as String?,
      wikipediaUrl: json['wikipedia_url'] as String?,
      routingLatitude: (json['routing_latitude'] as num?)?.toDouble(),
      routingLongitude: (json['routing_longitude'] as num?)?.toDouble(),
      routingPointSource: json['routing_point_source'] as String?,
      routingPointVerifiedOn: json['routing_point_verified_on'] as String?,
      routingAccessStatus:
          json['routing_access_status'] as String? ??
          'representative_point_only',
    );
  }

  static String? _validCatalogKey(Object? value) {
    if (value is! String) return null;
    final match = RegExp(r'[a-z][a-z0-9-]{0,79}').matchAsPrefix(value);
    return match?.group(0) == value ? value : null;
  }

  /// Pedestrian destination: the verified routing point when the catalog
  /// carries one, otherwise the display point. Markers and cards keep
  /// showing the display coordinate.
  double get routeLatitude => routingLatitude ?? latitude;
  double get routeLongitude => routingLongitude ?? longitude;

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'catalog_key': _validCatalogKey(catalogKey),
      'title': title,
      'short_description': shortDescription,
      'full_description': fullDescription,
      'category': category.key,
      'is_unusual': isUnusual,
      'latitude': latitude,
      'longitude': longitude,
      'address': address,
      'photo_url': photoUrl,
      'working_hours': workingHours,
      'tags': tags,
      'rating': rating,
      'architectural_style': architecturalStyle,
      'year_built': yearBuilt,
      'source_url': sourceUrl,
      'coordinate_kind': coordinateKind,
      'address_status': addressStatus,
      'recommended_visit_minutes': recommendedVisitMinutes,
      'why_visit': whyVisit,
      'visit_note': visitNote,
      'official_website': officialWebsite,
      'wikipedia_url': wikipediaUrl,
      'routing_latitude': routingLatitude,
      'routing_longitude': routingLongitude,
      'routing_point_source': routingPointSource,
      'routing_point_verified_on': routingPointVerifiedOn,
      'routing_access_status': routingAccessStatus,
    };
  }

  List<String> get tagList {
    if (tags == null || tags!.isEmpty) return [];
    return tags!
        .split(',')
        .map((t) => t.trim())
        .where((t) => t.isNotEmpty)
        .toList();
  }
}

class CategoryModel {
  final PlaceCategoryEnum id;
  final String name;
  final String description;
  final int count;

  CategoryModel({
    required this.id,
    required this.name,
    required this.description,
    required this.count,
  });

  factory CategoryModel.fromJson(Map<String, dynamic> json) {
    return CategoryModel(
      id: PlaceCategoryEnum.fromString(json['id'] as String),
      name: json['name'] as String,
      description: json['description'] as String,
      count: json['count'] as int? ?? 0,
    );
  }
}
