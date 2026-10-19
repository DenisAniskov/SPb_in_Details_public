import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:smart_navigator_spb/core/constants/app_colors.dart';
import 'package:smart_navigator_spb/core/constants/app_strings.dart';
import 'package:smart_navigator_spb/data/city_highlights/city_highlight_model.dart';
import 'package:smart_navigator_spb/data/city_highlights/city_highlights_catalog.dart';
import 'package:smart_navigator_spb/data/models/assistant_model.dart';
import 'package:smart_navigator_spb/data/models/historical_content_model.dart';
import 'package:smart_navigator_spb/data/models/place_model.dart';
import 'package:smart_navigator_spb/data/repositories/places_repository.dart';
import 'package:smart_navigator_spb/providers/assistant_provider.dart';
import 'package:smart_navigator_spb/providers/city_viewpoint_provider.dart';
import 'package:smart_navigator_spb/providers/historical_content_provider.dart';
import 'package:smart_navigator_spb/providers/routing_provider.dart';
import 'package:smart_navigator_spb/providers/tts_provider.dart';
import 'package:smart_navigator_spb/ui/widgets/assistant_sheet.dart';
import 'package:smart_navigator_spb/ui/widgets/city_highlight_sections.dart';
import 'package:smart_navigator_spb/ui/widgets/smart_walk_wizard_sheet.dart';
import 'package:smart_navigator_spb/ui/widgets/start_point_selector_dialog.dart';
import 'package:url_launcher/url_launcher.dart';

class PlaceDetailScreen extends StatefulWidget {
  final PlaceModel place;
  const PlaceDetailScreen({super.key, required this.place});
  @override
  State<PlaceDetailScreen> createState() => _PlaceDetailScreenState();
}

class _PlaceDetailScreenState extends State<PlaceDetailScreen> {
  late Future<PlaceModel?> _detail;
  @override
  void initState() {
    super.initState();
    _load();
  }

  void _load() {
    _detail = _loadVerifiedDetail();
  }

  Future<PlaceModel?> _loadVerifiedDetail() async {
    final current = await context.read<PlacesRepository>().getPlaceDetail(
      widget.place.id,
    );
    if (current == null) return null;
    final selected = widget.place;
    // A numeric ID can be reassigned between catalog resolution and this
    // detail request. Never replace the selected place with that other record.
    final sameIdentity = selected.catalogKey != null
        ? selected.catalogKey == current.catalogKey
        : selected.id == current.id &&
              selected.title == current.title &&
              selected.category == current.category &&
              selected.latitude == current.latitude &&
              selected.longitude == current.longitude;
    return sameIdentity ? current : null;
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<PlaceModel?>(
    future: _detail,
    builder: (context, snapshot) {
      if (snapshot.connectionState == ConnectionState.waiting) {
        return Scaffold(
          appBar: AppBar(title: Text(widget.place.title)),
          body: const Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                CircularProgressIndicator(),
                SizedBox(height: 12),
                Text('Загружаем карточку места…'),
              ],
            ),
          ),
        );
      }
      if (snapshot.hasError || snapshot.data == null) {
        return Scaffold(
          appBar: AppBar(title: Text(widget.place.title)),
          body: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text('Не удалось обновить сведения о месте'),
                TextButton(
                  onPressed: () => setState(_load),
                  child: const Text('Повторить'),
                ),
              ],
            ),
          ),
        );
      }
      return _PlaceDetailBody(place: snapshot.data!);
    },
  );
}

class _PlaceDetailBody extends StatefulWidget {
  final PlaceModel place;

  const _PlaceDetailBody({required this.place});

  @override
  State<_PlaceDetailBody> createState() => _PlaceDetailBodyState();
}

class _PlaceDetailBodyState extends State<_PlaceDetailBody> {
  final GlobalKey _historyKey = GlobalKey();
  final ScrollController _scroll = ScrollController();
  TtsProvider? _tts;
  bool _narrationResetDone = false;

  PlaceModel get place => widget.place;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _tts = context.read<TtsProvider?>();
    // Opening another place card takes over the story button. A story from
    // the previous card is stopped here without touching navigation speech.
    if (!_narrationResetDone) {
      _narrationResetDone = true;
      final provider = _tts;
      if (provider?.isNarrating ?? false) {
        // Outside the build pass: the provider notifies its listeners.
        scheduleMicrotask(() => unawaited(provider!.stopNarration()));
      }
    }
  }

  @override
  void dispose() {
    final provider = _tts;
    if (provider?.isNarrating ?? false) {
      scheduleMicrotask(() => unawaited(provider!.stopNarration()));
    }
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _openAssistant() async {
    final assistant = context.read<AssistantProvider?>();
    if (assistant == null) return;
    assistant.prepare(placeId: place.id, placeTitle: place.title);
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => AssistantSheet(
        initialQuestion: 'Расскажи об этом месте',
        initialPlaceId: place.id,
        onOpenPlace: _openAssistantPlace,
        onOpenSmartWalk: _openAssistantSmartWalk,
      ),
    );
  }

  Future<void> _openAssistantPlace(AssistantPlaceReference reference) async {
    if (!mounted) return;
    try {
      final detail = await context.read<PlacesRepository>().getPlaceDetail(
        reference.id,
      );
      if (detail == null || !mounted) return;
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => PlaceDetailScreen(place: detail),
        ),
      );
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Не удалось открыть место. Повторите позже.'),
        ),
      );
    }
  }

  void _openAssistantSmartWalk() {
    if (!mounted) return;
    if (context.read<RoutingProvider>().navigationLocked) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Сначала завершите текущую навигацию.')),
      );
      return;
    }
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => const SmartWalkWizardSheet(),
    );
  }

  void _scrollToHistory() {
    final target = _historyKey.currentContext;
    if (target == null) return;
    Scrollable.ensureVisible(
      target,
      duration: const Duration(milliseconds: 350),
      curve: Curves.easeInOut,
      alignment: 0.05,
    );
  }

  /// C14: the card is closed and the existing map is asked to focus the
  /// confirmed public point. No route is built or changed by this action.
  void _showViewpointOnMap(CityViewpoint viewpoint) {
    if (context.read<RoutingProvider>().navigationLocked) {
      ScaffoldMessenger.of(context)
        ..clearSnackBars()
        ..showSnackBar(
          const SnackBar(
            content: Text('Сначала завершите текущую навигацию.'),
            behavior: SnackBarBehavior.floating,
          ),
        );
      return;
    }
    final provider = context.read<CityViewpointProvider?>();
    if (provider == null) return;
    provider.show(place, viewpoint);
    Navigator.of(context).popUntil((route) => route.isFirst);
  }

  /// One visible entry point for the C6 historical card. Lazy loading, the
  /// confirmed-absence state and the retryable error stay three distinct
  /// states; none of them blocks the main place card.
  Widget? _historyEntryPoint(
    BuildContext context,
    HistoricalContentProvider? provider,
    HistoricalContent? history,
  ) {
    final palette = AppPalette.of(context);
    if (history != null) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          OutlinedButton.icon(
            onPressed: _scrollToHistory,
            icon: const Icon(Icons.menu_book_outlined),
            label: const Text('Читать историю места'),
            style: OutlinedButton.styleFrom(
              alignment: Alignment.centerLeft,
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              minimumSize: const Size.fromHeight(48),
            ),
          ),
          const SizedBox(height: 4),
          Text(
            'Факты, хронология, личности и источники — ниже в карточке.',
            style: TextStyle(fontSize: 12, color: palette.textMuted),
          ),
        ],
      );
    }
    if (provider == null) return null;
    if (provider.hasFailed(place.id)) {
      return Row(
        children: [
          Icon(Icons.error_outline, size: 18, color: palette.error),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              'Не удалось загрузить историческую справку',
              style: TextStyle(fontSize: 13, color: palette.textSecondary),
            ),
          ),
          TextButton(
            onPressed: () => provider.retry(place),
            child: const Text('Повторить'),
          ),
        ],
      );
    }
    if (!provider.hasResolved(place.id)) {
      return Row(
        children: [
          SizedBox(
            width: 16,
            height: 16,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: palette.primary,
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'Загружаем историческую справку…',
              style: TextStyle(fontSize: 13, color: palette.textSecondary),
            ),
          ),
        ],
      );
    }
    return Row(
      children: [
        Icon(Icons.history_toggle_off, size: 18, color: palette.textMuted),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            'Историческая справка пока не подготовлена.',
            style: TextStyle(fontSize: 13, color: palette.textSecondary),
          ),
        ),
      ],
    );
  }

  Future<void> _launchExternal(BuildContext context, String rawUrl) async {
    final uri = Uri.tryParse(rawUrl);
    if (uri == null) {
      _showLinkFailure(context);
      return;
    }
    try {
      final launched = await launchUrl(
        uri,
        mode: LaunchMode.externalApplication,
      );
      if (!context.mounted) return;
      if (!launched) _showLinkFailure(context);
    } catch (_) {
      if (!context.mounted) return;
      _showLinkFailure(context);
    }
  }

  void _showLinkFailure(BuildContext context) {
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(
        const SnackBar(
          content: Text('Не удалось открыть ссылку'),
          duration: Duration(seconds: 2),
          behavior: SnackBarBehavior.floating,
        ),
      );
  }

  @override
  Widget build(BuildContext context) {
    final routingProvider = context.watch<RoutingProvider>();
    final startPoint = routingProvider.startPoint;
    // Phase C6: verified historical content is loaded lazily, once per
    // place; a missing card shows nothing extra — no empty headers. The
    // provider is optional by design: the historical layer must never be a
    // hard dependency of the place screen.
    final historyProvider = context.watch<HistoricalContentProvider?>();
    final history = historyProvider?.contentFor(place.id);
    historyProvider?.ensureLoaded(place);
    // C14 is local and optional: no request, no loading state and no section
    // at all when the catalog has no card for this place.
    final highlight = CityHighlightsCatalog.forPlace(place);
    final tts = context.watch<TtsProvider?>();

    return Scaffold(
      backgroundColor: AppPalette.of(context).background,
      body: CustomScrollView(
        controller: _scroll,
        physics: const BouncingScrollPhysics(),
        slivers: [
          // Шапка с фото и кнопкой назад
          SliverAppBar(
            expandedHeight: 260,
            pinned: true,
            backgroundColor: AppPalette.of(context).primary,
            leading: Padding(
              padding: const EdgeInsets.all(8.0),
              child: CircleAvatar(
                backgroundColor: Colors.black.withValues(alpha: 0.5),
                child: IconButton(
                  tooltip: 'Назад',
                  icon: const Icon(
                    Icons.arrow_back,
                    color: Colors.white,
                    size: 20,
                  ),
                  onPressed: () => Navigator.pop(context),
                ),
              ),
            ),
            flexibleSpace: FlexibleSpaceBar(
              background: Stack(
                fit: StackFit.expand,
                children: [
                  Container(
                    color: AppPalette.of(context)
                        .category(place.category.color),
                    child: Icon(
                      place.category.icon,
                      size: 72,
                      color: Colors.white,
                    ),
                  ),
                  // Градиентная подложка
                  Container(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [
                          Colors.black.withValues(alpha: 0.4),
                          Colors.transparent,
                          Colors.black.withValues(alpha: 0.7),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),

          // Тело карточки
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Бейджи
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 6,
                        ),
                        decoration: BoxDecoration(
                          color: place.category.color.withValues(alpha: 0.14),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Wrap(
                          crossAxisAlignment: WrapCrossAlignment.center,
                          children: [
                            Icon(
                              place.category.icon,
                              size: 15,
                              color: AppPalette.of(context)
                                  .category(place.category.color),
                            ),
                            const SizedBox(width: 5),
                            Text(
                              place.category.displayName,
                              style: TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.bold,
                                color: AppPalette.of(context)
                                    .category(place.category.color),
                              ),
                            ),
                          ],
                        ),
                      ),
                      if (place.isUnusual)
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 6,
                          ),
                          decoration: BoxDecoration(
                            color: AppPalette.of(context).unusualBadge
                                .withValues(alpha: 0.14),
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Wrap(
                            crossAxisAlignment: WrapCrossAlignment.center,
                            children: [
                              Icon(
                                Icons.auto_awesome,
                                size: 13,
                                color: AppPalette.of(context).unusualBadge,
                              ),
                              const SizedBox(width: 4),
                              Text(
                                AppStrings.unusualBadgeText,
                                style: TextStyle(
                                  fontSize: 11,
                                  fontWeight: FontWeight.bold,
                                  color: AppPalette.of(context).unusualBadge,
                                ),
                              ),
                            ],
                          ),
                        ),

                      // Время посещения
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 6,
                        ),
                        decoration: BoxDecoration(
                          color: AppPalette.of(context).surfaceVariant,
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Wrap(
                          crossAxisAlignment: WrapCrossAlignment.center,
                          children: [
                            Icon(
                              Icons.access_time,
                              size: 14,
                              color: AppPalette.of(context).textSecondary,
                            ),
                            const SizedBox(width: 4),
                            Text(
                              '~${place.recommendedVisitMinutes} мин на осмотр',
                              style: TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.w600,
                                color: AppPalette.of(context).textSecondary,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),

                  // Название
                  Text(
                    place.title,
                    style: TextStyle(
                      fontSize: 24,
                      fontWeight: FontWeight.bold,
                      color: AppPalette.of(context).textPrimary,
                      letterSpacing: -0.5,
                    ),
                  ),
                  const SizedBox(height: 12),

                  // Адрес
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(
                        Icons.location_on,
                        size: 20,
                        color: AppPalette.of(context).primary,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          place.address,
                          style: TextStyle(
                            fontSize: 14,
                            color: AppPalette.of(context).textSecondary,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),

                  // Редакторские пометки об источнике и достоверности данных
                  Text(
                    'Время осмотра — редакторская оценка',
                    style: TextStyle(
                      fontSize: 12,
                      height: 1.35,
                      color: AppPalette.of(context).textMuted,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    place.sourceUrl != null
                        ? 'Координаты объекта из OpenStreetMap. Вход и проход требуют проверки.'
                        : 'Источник координат не подтверждён.',
                    style: TextStyle(
                      fontSize: 12,
                      height: 1.35,
                      color: AppPalette.of(context).textMuted,
                    ),
                  ),
                  if (place.addressStatus != 'osm_tags')
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Text(
                        'Адрес предварительный, требует проверки.',
                        style: TextStyle(
                          fontSize: 12,
                          height: 1.35,
                          color: AppPalette.of(context).textMuted,
                        ),
                      ),
                    ),
                  if (place.sourceUrl != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: SelectableText(
                        place.sourceUrl!,
                        style: TextStyle(
                          fontSize: 11,
                          color: AppPalette.of(context).textMuted,
                        ),
                      ),
                    ),
                  const SizedBox(height: 20),

                  // Карточка старта и маршрута
                  Container(
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: AppPalette.of(context).surface,
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(color: AppPalette.of(context).border),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Wrap(
                          children: [
                            const Icon(
                              Icons.trip_origin,
                              size: 18,
                              color: AppColors.routeStartMarker,
                            ),
                            const SizedBox(width: 8),
                            Text(
                              AppStrings.startPointLabel,
                              style: TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.bold,
                                color: AppPalette.of(context).textSecondary,
                              ),
                            ),

                            TextButton(
                              style: TextButton.styleFrom(
                                padding: EdgeInsets.zero,
                                minimumSize: const Size(48, 48),
                                tapTargetSize: MaterialTapTargetSize.padded,
                              ),
                              onPressed: () {
                                showDialog(
                                  context: context,
                                  builder: (_) =>
                                      const StartPointSelectorDialog(),
                                );
                              },
                              child: const Text(
                                AppStrings.changeStartPoint,
                                style: TextStyle(
                                  fontSize: 13,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 4),
                        Padding(
                          padding: const EdgeInsets.only(left: 26),
                          child: Text(
                            startPoint.title,
                            style: TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.w600,
                              color: AppPalette.of(context).textPrimary,
                            ),
                          ),
                        ),
                        const SizedBox(height: 14),
                        Row(
                          children: [
                            Expanded(
                              child: ElevatedButton.icon(
                                icon: const Icon(
                                  Icons.directions_walk,
                                  size: 18,
                                ),
                                label: const Text(
                                  AppStrings.buildPedestrianRoute,
                                  style: TextStyle(
                                    fontSize: 13,
                                    fontWeight: FontWeight.bold,
                                  ),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                                style: ElevatedButton.styleFrom(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 8,
                                    vertical: 10,
                                  ),
                                ),
                                onPressed: () {
                                  routingProvider.buildRouteTo(place);
                                  Navigator.pop(context);
                                },
                              ),
                            ),
                            const SizedBox(width: 8),
                            IconButton.filledTonal(
                              tooltip: routingProvider.isInWalk(place)
                                  ? 'Удалить из прогулки'
                                  : 'Добавить в прогулку',
                              style: IconButton.styleFrom(
                                backgroundColor: routingProvider.isInWalk(place)
                                    ? AppPalette.of(context).primary
                                    : AppPalette.of(context).surface,
                                foregroundColor: routingProvider.isInWalk(place)
                                    ? AppPalette.of(context).onSolid
                                    : AppPalette.of(context).primary,
                                padding: const EdgeInsets.all(10),
                                minimumSize: const Size(48, 48),
                              ),
                              icon: Icon(
                                routingProvider.isInWalk(place)
                                    ? Icons.playlist_add_check
                                    : Icons.playlist_add,
                                size: 22,
                              ),
                              onPressed: () {
                                final isAdded = routingProvider.isInWalk(place);
                                if (isAdded) {
                                  routingProvider.removePlaceFromWalk(place.id);
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    const SnackBar(
                                      content: Text('Удалено из прогулки'),
                                      duration: Duration(seconds: 2),
                                    ),
                                  );
                                } else {
                                  final success = routingProvider
                                      .addPlaceToWalk(place);
                                  if (success) {
                                    ScaffoldMessenger.of(context).showSnackBar(
                                      SnackBar(
                                        content: Text(
                                          'Добавлено в прогулку (${routingProvider.walkPlaces.length} из ${RoutingProvider.maxWalkPlaces})',
                                        ),
                                        duration: const Duration(seconds: 2),
                                      ),
                                    );
                                  } else {
                                    ScaffoldMessenger.of(context).showSnackBar(
                                      SnackBar(
                                        content: const Text(
                                          'Лимит прогулки — максимум ${RoutingProvider.maxWalkPlaces} мест',
                                        ),
                                        backgroundColor: AppPalette.of(context)
                                            .error,
                                        duration: const Duration(seconds: 3),
                                      ),
                                    );
                                  }
                                }
                              },
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 24),

                  // Описание места
                  Text(
                    AppStrings.detailsTitle,
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                      color: AppPalette.of(context).textPrimary,
                    ),
                  ),
                  const SizedBox(height: 10),
                  Text(
                    place.fullDescription ?? place.shortDescription,
                    style: TextStyle(
                      fontSize: 15,
                      color: AppPalette.of(context).textPrimary,
                      height: 1.55,
                    ),
                  ),
                  if (highlight != null) ...[
                    const SizedBox(height: 18),
                    CityHighlightSections(
                      highlight: highlight,
                      tts: tts,
                      onShowViewpoint: highlight.hasViewpoint
                          ? () => _showViewpointOnMap(highlight.viewpoint!)
                          : null,
                    ),
                  ],
                  const SizedBox(height: 16),
                  OutlinedButton(
                    onPressed: context.read<AssistantProvider?>() == null
                        ? null
                        : _openAssistant,
                    style: OutlinedButton.styleFrom(
                      alignment: Alignment.centerLeft,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 12,
                      ),
                      minimumSize: const Size.fromHeight(48),
                    ),
                    child: const Row(
                      children: [
                        Icon(Icons.smart_toy_outlined),
                        SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            'Спросить ИИ об этом месте',
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (_historyEntryPoint(context, historyProvider, history)
                      case final entry?) ...[
                    const SizedBox(height: 18),
                    entry,
                  ],
                  const SizedBox(height: 24),

                  // Почему стоит посетить
                  if (place.whyVisit != null && place.whyVisit!.isNotEmpty) ...[
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: AppPalette.of(context).primary
                            .withValues(alpha: 0.08),
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(
                          color: AppPalette.of(context).primary
                              .withValues(alpha: 0.25),
                        ),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Icon(
                                Icons.auto_awesome,
                                size: 18,
                                color: AppPalette.of(context).primary,
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  'Почему стоит посетить',
                                  style: TextStyle(
                                    fontSize: 15,
                                    fontWeight: FontWeight.bold,
                                    color: AppPalette.of(context).primary,
                                  ),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 8),
                          Text(
                            place.whyVisit!,
                            style: TextStyle(
                              fontSize: 14,
                              color: AppPalette.of(context).textPrimary,
                              height: 1.45,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 16),
                  ],

                  // Phase C6: проверенная историческая справка. Секции
                  // показываются только при наличии данных — без пустых
                  // заголовков и ложных обещаний.
                  if (history != null) ...[
                    _ShortHistoryCard(key: _historyKey, history: history),
                    if (history.hasFacts) ...[
                      const SizedBox(height: 16),
                      _HistoryFactsSection(facts: history.facts),
                    ],
                    if (history.hasTimeline) ...[
                      const SizedBox(height: 16),
                      _HistoryTimelineSection(events: history.timeline),
                    ],
                    if (history.hasPeople) ...[
                      const SizedBox(height: 16),
                      _HistoryPeopleSection(people: history.people),
                    ],
                    if (history.detailedHistoricalText.isNotEmpty) ...[
                      const SizedBox(height: 16),
                      _DetailedHistorySection(history: history),
                    ],
                    if (history.hasSources) ...[
                      const SizedBox(height: 16),
                      _HistorySourcesSection(
                        sources: history.sources,
                        onOpenLink: _launchExternal,
                      ),
                    ],
                    const SizedBox(height: 24),
                  ],

                  // Совет к прогулке / Контекст посещения
                  if (place.visitNote != null &&
                      place.visitNote!.isNotEmpty) ...[
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: AppPalette.of(context).surfaceVariant
                            .withValues(alpha: 0.5),
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(
                          color: AppPalette.of(context).border,
                        ),
                      ),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Icon(
                            Icons.info_outline,
                            size: 18,
                            color: AppPalette.of(context).secondary,
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  'Контекст прогулки',
                                  style: TextStyle(
                                    fontSize: 13,
                                    fontWeight: FontWeight.bold,
                                    color: AppPalette.of(context).secondary,
                                  ),
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  place.visitNote!,
                                  style: TextStyle(
                                    fontSize: 13,
                                    color: AppPalette.of(context).textSecondary,
                                    height: 1.4,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 24),
                  ],

                  // Дополнительные параметры (стиль, год, часы работы)
                  if (place.architecturalStyle != null ||
                      place.yearBuilt != null) ...[
                    Container(
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: AppPalette.of(context).surfaceVariant
                            .withValues(alpha: 0.6),
                        borderRadius: BorderRadius.circular(16),
                      ),
                      child: Column(
                        children: [
                          if (place.architecturalStyle != null)
                            _InfoRow(
                              icon: Icons.account_balance_outlined,
                              label: AppStrings.styleLabel,
                              value: place.architecturalStyle!,
                            ),
                          if (place.yearBuilt != null) ...[
                            const Divider(height: 16),
                            _InfoRow(
                              icon: Icons.history_edu,
                              label: AppStrings.yearBuiltLabel,
                              value: place.yearBuilt!,
                            ),
                          ],
                        ],
                      ),
                    ),
                    const SizedBox(height: 24),
                  ],

                  // Теги
                  if (place.tagList.isNotEmpty) ...[
                    Text(
                      AppStrings.tagsLabel,
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                        color: AppPalette.of(context).textPrimary,
                      ),
                    ),
                    const SizedBox(height: 10),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: place.tagList.map((tag) {
                        return Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 6,
                          ),
                          decoration: BoxDecoration(
                            color: AppPalette.of(context).surface,
                            borderRadius: BorderRadius.circular(20),
                            border: Border.all(
                              color: AppPalette.of(context).border,
                            ),
                          ),
                          child: Text(
                            '#$tag',
                            style: TextStyle(
                              fontSize: 13,
                              color: AppPalette.of(context).primary,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        );
                      }).toList(),
                    ),
                    const SizedBox(height: 32),
                  ],

                  // Проверенные ссылки из источников (OSM)
                  if (place.officialWebsite != null ||
                      place.wikipediaUrl != null) ...[
                    Text(
                      'Проверенные источники',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                        color: AppPalette.of(context).textPrimary,
                      ),
                    ),
                    const SizedBox(height: 10),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        if (place.officialWebsite != null)
                          OutlinedButton.icon(
                            icon: const Icon(Icons.language, size: 16),
                            label: const Text('Официальный сайт'),
                            style: OutlinedButton.styleFrom(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 12,
                                vertical: 8,
                              ),
                              minimumSize: const Size(48, 48),
                            ),
                            onPressed: () async {
                              await _launchExternal(
                                context,
                                place.officialWebsite!,
                              );
                            },
                          ),
                        if (place.wikipediaUrl != null)
                          OutlinedButton.icon(
                            icon: const Icon(Icons.menu_book, size: 16),
                            label: const Text('Википедия'),
                            style: OutlinedButton.styleFrom(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 12,
                                vertical: 8,
                              ),
                              minimumSize: const Size(48, 48),
                            ),
                            onPressed: () async {
                              await _launchExternal(
                                context,
                                place.wikipediaUrl!,
                              );
                            },
                          ),
                      ],
                    ),
                    const SizedBox(height: 32),
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _InfoRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;

  const _InfoRow({
    required this.icon,
    required this.label,
    required this.value,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 18, color: AppPalette.of(context).primary),
        const SizedBox(width: 8),
        Expanded(
          flex: 2,
          child: Text(
            label,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: AppPalette.of(context).textSecondary,
            ),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          flex: 3,
          child: Text(
            value,
            style: TextStyle(
              fontSize: 13,
              color: AppPalette.of(context).textPrimary,
              fontWeight: FontWeight.w500,
            ),
          ),
        ),
      ],
    );
  }
}

/// Phase C6: заголовок исторической секции — единый стиль для всех блоков.
class _HistorySectionHeader extends StatelessWidget {
  final IconData icon;
  final String title;
  final Color color;

  const _HistorySectionHeader({
    required this.icon,
    required this.title,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, size: 18, color: color),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            title,
            style: TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.bold,
              color: color,
            ),
          ),
        ),
      ],
    );
  }
}

/// «Краткая история»: 2–4 проверенных предложения + период (если задан).
class _ShortHistoryCard extends StatelessWidget {
  final HistoricalContent history;

  const _ShortHistoryCard({super.key, required this.history});

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: palette.primary.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: palette.primary.withValues(alpha: 0.22)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _HistorySectionHeader(
            icon: Icons.history_edu,
            title: 'Краткая история',
            color: palette.primary,
          ),
          const SizedBox(height: 8),
          Text(
            history.shortHistoricalSummary,
            style: TextStyle(
              fontSize: 14.5,
              height: 1.5,
              color: palette.textPrimary,
            ),
          ),
          if (history.period != null && history.period!.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(
              'Период: ${history.period}',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: palette.textSecondary,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// «Интересные факты»: небольшие тематические карточки.
class _HistoryFactsSection extends StatelessWidget {
  final List<HistoricalFact> facts;

  const _HistoryFactsSection({required this.facts});

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _HistorySectionHeader(
          icon: Icons.lightbulb_outline,
          title: 'Интересные факты',
          color: palette.secondary,
        ),
        const SizedBox(height: 10),
        for (var i = 0; i < facts.length; i++)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: palette.surface,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: palette.border),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    facts[i].title,
                    style: TextStyle(
                      fontSize: 13.5,
                      fontWeight: FontWeight.bold,
                      color: palette.textPrimary,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    facts[i].text,
                    style: TextStyle(
                      fontSize: 13,
                      height: 1.45,
                      color: palette.textSecondary,
                    ),
                  ),
                  if (facts[i].categoryLabel.isNotEmpty) ...[
                    const SizedBox(height: 6),
                    Text(
                      facts[i].categoryLabel,
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                        color: palette.textMuted,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
      ],
    );
  }
}

/// «Важные даты»: компактная хронология только из проверенных событий.
class _HistoryTimelineSection extends StatelessWidget {
  final List<HistoricalTimelineEvent> events;

  const _HistoryTimelineSection({required this.events});

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _HistorySectionHeader(
          icon: Icons.event,
          title: 'Важные даты',
          color: palette.secondary,
        ),
        const SizedBox(height: 10),
        for (final event in events)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  constraints: const BoxConstraints(
                    minWidth: 64,
                    maxWidth: 150,
                  ),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: palette.surfaceVariant.withValues(alpha: 0.6),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    event.dateLabel,
                    style: TextStyle(
                      fontSize: 11.5,
                      fontWeight: FontWeight.bold,
                      color: palette.primary,
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        event.title,
                        style: TextStyle(
                          fontSize: 13.5,
                          fontWeight: FontWeight.w600,
                          color: palette.textPrimary,
                        ),
                      ),
                      Text(
                        event.description,
                        style: TextStyle(
                          fontSize: 12.5,
                          height: 1.4,
                          color: palette.textSecondary,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

/// «Архитектура и личности»: только подтверждённые атрибуции.
class _HistoryPeopleSection extends StatelessWidget {
  final List<HistoricalPerson> people;

  const _HistoryPeopleSection({required this.people});

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _HistorySectionHeader(
          icon: Icons.architecture,
          title: 'Личности',
          color: palette.secondary,
        ),
        const SizedBox(height: 10),
        for (final person in people)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  person.roleLabel.isEmpty
                      ? person.name
                      : '${person.name} — ${person.roleLabel}',
                  style: TextStyle(
                    fontSize: 13.5,
                    fontWeight: FontWeight.bold,
                    color: palette.textPrimary,
                  ),
                ),
                if (person.description != null &&
                    person.description!.isNotEmpty)
                  Text(
                    person.description!,
                    style: TextStyle(
                      fontSize: 12.5,
                      height: 1.4,
                      color: palette.textSecondary,
                    ),
                  ),
              ],
            ),
          ),
      ],
    );
  }
}

/// «История и особенности»: разворачиваемый подробный текст.
class _DetailedHistorySection extends StatelessWidget {
  final HistoricalContent history;

  const _DetailedHistorySection({required this.history});

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        color: palette.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: palette.border),
      ),
      child: Theme(
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: Material(
          type: MaterialType.transparency,
          child: ExpansionTile(
            tilePadding: EdgeInsets.zero,
            childrenPadding: const EdgeInsets.fromLTRB(0, 0, 0, 12),
            initiallyExpanded: false,
            iconColor: palette.textSecondary,
            collapsedIconColor: palette.textSecondary,
            title: Text(
              'История и особенности',
              style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.bold,
                color: palette.secondary,
              ),
            ),
            children: [
              Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  history.detailedHistoricalText,
                  style: TextStyle(
                    fontSize: 14,
                    height: 1.55,
                    color: palette.textPrimary,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// «Источники»: список проверенных материалов со ссылками (открываются
/// только внешним браузером, содержимое страниц не загружается).
class _HistorySourcesSection extends StatelessWidget {
  final List<HistoricalSource> sources;
  final Future<void> Function(BuildContext, String) onOpenLink;

  const _HistorySourcesSection({
    required this.sources,
    required this.onOpenLink,
  });

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _HistorySectionHeader(
          icon: Icons.fact_check_outlined,
          title: 'Источники',
          color: palette.secondary,
        ),
        const SizedBox(height: 10),
        for (final source in sources)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: palette.surface,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: palette.border),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(source.icon, size: 16, color: palette.primary),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          source.title,
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                            color: palette.textPrimary,
                          ),
                        ),
                      ),
                    ],
                  ),
                  if (source.notes != null && source.notes!.isNotEmpty) ...[
                    const SizedBox(height: 4),
                    Text(
                      source.notes!,
                      style: TextStyle(
                        fontSize: 11.5,
                        height: 1.35,
                        color: palette.textMuted,
                      ),
                    ),
                  ],
                  const SizedBox(height: 8),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: OutlinedButton.icon(
                      icon: const Icon(Icons.open_in_new, size: 14),
                      label: Text(
                        source.typeLabel,
                        style: const TextStyle(fontSize: 12),
                      ),
                      style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 8,
                        ),
                        minimumSize: const Size(48, 40),
                      ),
                      onPressed: () => onOpenLink(context, source.url),
                    ),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }
}
