import 'package:smart_navigator_spb/core/network/ui_error.dart';

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:smart_navigator_spb/core/constants/app_colors.dart';
import 'package:smart_navigator_spb/core/constants/app_strings.dart';
import 'package:smart_navigator_spb/core/constants/map_constants.dart';
import 'package:smart_navigator_spb/data/models/route_point_model.dart';
import 'package:smart_navigator_spb/data/models/suggest_item_model.dart';
import 'package:smart_navigator_spb/data/repositories/search_repository.dart';
import 'package:smart_navigator_spb/providers/location_provider.dart';
import 'package:smart_navigator_spb/providers/routing_provider.dart';

class StartPointSelectorDialog extends StatefulWidget {
  final SearchRepository? repository;
  final RoutePointModel? currentStart;
  final ValueChanged<RoutePointModel>? onSelected;
  final VoidCallback? onChooseMap;

  const StartPointSelectorDialog({
    super.key,
    this.repository,
    this.currentStart,
    this.onSelected,
    this.onChooseMap,
  });

  @override
  State<StartPointSelectorDialog> createState() =>
      _StartPointSelectorDialogState();
}

class _StartPointSelectorDialogState extends State<StartPointSelectorDialog> {
  bool _isSearchingAddress = false;
  final TextEditingController _searchController = TextEditingController();
  Timer? _debounce;
  List<SuggestItemModel> _suggestions = [];
  bool _isLoading = false;
  String? _errorMessage;
  int _requestId = 0;
  bool _isResolving = false;
  String? _lastQuery;
  late final SearchRepository _searchRepository;

  void _selectPoint(RoutePointModel point) {
    if (widget.onSelected case final onSelected?) {
      onSelected(point);
    } else {
      context.read<RoutingProvider>().setStartPoint(point);
    }
    Navigator.pop(context);
  }

  @override
  void initState() {
    super.initState();
    _searchRepository =
        widget.repository ??
        Provider.of<SearchRepository?>(context, listen: false) ??
        SearchRepository();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _searchController.dispose();
    super.dispose();
  }

  void _onSearchChanged(String query) {
    if (query.trim() == _lastQuery) return;
    _lastQuery = query.trim();
    _debounce?.cancel();
    _requestId++;
    final currentReq = _requestId;
    final trimmed = query.trim();

    if (trimmed.length < 2) {
      setState(() {
        _isResolving = false;
        _suggestions = [];
        _isLoading = false;
        _errorMessage = null;
      });
      return;
    }

    setState(() {
      _suggestions = [];
      _isResolving = false;
      _isLoading = true;
      _errorMessage = null;
    });

    _debounce = Timer(const Duration(milliseconds: 350), () async {
      try {
        final results = await _searchRepository.getSuggestions(trimmed);
        if (!mounted || currentReq != _requestId) return;
        setState(() {
          _suggestions = results;
          _isLoading = false;
        });
      } catch (e) {
        if (!mounted || currentReq != _requestId) return;
        setState(() {
          _suggestions = [];
          _isLoading = false;
          _errorMessage = searchUiError(e);
        });
      }
    });
  }

  Future<void> _selectSuggestion(SuggestItemModel item) async {
    if (_isResolving) return;
    final requestId = ++_requestId;
    _debounce?.cancel();
    _lastQuery = null;
    setState(() {
      _isResolving = true;
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      final point = await _searchRepository.resolveGeocode(
        uri: item.uri,
        text: [
          item.title,
          if (item.subtitle != null) item.subtitle!,
        ].join(', '),
      );
      if (!mounted || requestId != _requestId) return;

      final routePoint = point.toRoutePoint();
      _selectPoint(routePoint);

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Точка старта: ${routePoint.title}'),
          duration: const Duration(seconds: 2),
          behavior: SnackBarBehavior.floating,
        ),
      );
    } catch (e) {
      if (!mounted || requestId != _requestId) return;
      setState(() {
        _isResolving = false;
        _isLoading = false;
        _errorMessage = searchUiError(e);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final routingProvider = context.watch<RoutingProvider>();
    final currentStart = widget.currentStart ?? routingProvider.startPoint;

    return AlertDialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      titlePadding: const EdgeInsets.fromLTRB(20, 20, 20, 8),
      contentPadding: const EdgeInsets.symmetric(horizontal: 16),
      actionsPadding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
      title: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: AppPalette.of(context).primary.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(
              Icons.trip_origin,
              color: AppPalette.of(context).primary,
              size: 22,
            ),
          ),
          const SizedBox(width: 12),
          const Expanded(
            child: Text(
              AppStrings.startPointDialogTitle,
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
          ),
        ],
      ),
      content: SizedBox(
        width: double.maxFinite,
        height: MediaQuery.sizeOf(context).height * 0.6,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
                child: Text(
                  'Выберите один из 4 способов задания старта:',
                  style: TextStyle(
                    fontSize: 12,
                    color: AppPalette.of(context).textSecondary,
                  ),
                ),
              ),
              const SizedBox(height: 6),

              // Кнопки способов: 1. Выбрать на карте | 2. Найти адрес или место
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10),
                        ),
                        side: BorderSide(
                          color: _isSearchingAddress
                              ? AppPalette.of(context).divider
                              : AppPalette.of(context).primary,
                        ),
                      ),
                      onPressed: () {
                        if (widget.onChooseMap case final onChooseMap?) {
                          Navigator.of(context).pop();
                          onChooseMap();
                        } else {
                          context.read<RoutingProvider>().beginStartSelection();
                          Navigator.of(context)
                              .popUntil((route) => route.isFirst);
                        }
                      },
                      icon: const Icon(Icons.touch_app, size: 16),
                      label: const Text(
                        'Выбрать на карте',
                        style: TextStyle(fontSize: 12),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: FilledButton.icon(
                      style: FilledButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        backgroundColor: _isSearchingAddress
                            ? AppPalette.of(context).primary
                            : AppPalette.of(context).surfaceVariant,
                        foregroundColor: _isSearchingAddress
                            ? Colors.white
                            : AppPalette.of(context).textPrimary,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10),
                        ),
                      ),
                      onPressed: () {
                        if (_isSearchingAddress) _onSearchChanged('');
                        setState(() {
                          _isSearchingAddress = !_isSearchingAddress;
                          if (!_isSearchingAddress) {
                            _searchController.clear();
                            _suggestions = [];
                            _errorMessage = null;
                          }
                        });
                      },
                      icon: Icon(
                        _isSearchingAddress ? Icons.close : Icons.search,
                        size: 16,
                      ),
                      label: Text(
                        _isSearchingAddress ? 'Отмена' : 'Найти адрес',
                        style: const TextStyle(fontSize: 12),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),

              // Поле поиска адреса через Yandex Suggest (если активен поиск)
              if (_isSearchingAddress) ...[
                TextField(
                  controller: _searchController,
                  autofocus: true,
                  decoration: InputDecoration(
                    hintText: 'Введите адрес или вокзал...',
                    hintStyle: const TextStyle(fontSize: 13),
                    isDense: true,
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 10,
                    ),
                    prefixIcon: const Icon(Icons.search, size: 18),
                    suffixIcon: _searchController.text.isNotEmpty
                        ? IconButton(
                            icon: const Icon(Icons.clear, size: 18),
                            onPressed: () {
                              _searchController.clear();
                              _onSearchChanged('');
                            },
                          )
                        : null,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(10),
                    ),
                  ),
                  onChanged: _onSearchChanged,
                ),
                if (_isLoading)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 8),
                    child: Center(
                      child: SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    ),
                  ),
                if (_errorMessage != null)
                  Padding(
                    padding: const EdgeInsets.all(8),
                    child: Text(
                      _errorMessage!,
                      style: TextStyle(
                        fontSize: 12,
                        color: AppPalette.of(context).error,
                      ),
                    ),
                  ),
                if (_suggestions.isNotEmpty)
                  Flexible(
                    child: Container(
                      constraints: const BoxConstraints(maxHeight: 200),
                      margin: const EdgeInsets.only(top: 6),
                      child: ListView.separated(
                        shrinkWrap: true,
                        itemCount: _suggestions.length,
                        separatorBuilder: (_, __) => const Divider(height: 1),
                        itemBuilder: (context, index) {
                          final item = _suggestions[index];
                          return ListTile(
                            dense: true,
                            contentPadding: const EdgeInsets.symmetric(
                              horizontal: 6,
                              vertical: 0,
                            ),
                            leading: Icon(
                              Icons.location_on,
                              size: 18,
                              color: AppPalette.of(context).accent,
                            ),
                            title: Text(
                              item.title,
                              style: const TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            subtitle: item.subtitle != null
                                ? Text(
                                    item.subtitle!,
                                    style: const TextStyle(fontSize: 11),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  )
                                : null,
                            onTap: _isResolving
                                ? null
                                : () => _selectSuggestion(item),
                          );
                        },
                      ),
                    ),
                  ),
                if (!_isLoading &&
                    _searchController.text.trim().length >= 2 &&
                    _suggestions.isEmpty &&
                    _errorMessage == null)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: Center(
                      child: Text(
                        'Ничего не найдено',
                        style: TextStyle(
                          fontSize: 12,
                          color: AppPalette.of(context).textSecondary,
                        ),
                      ),
                    ),
                  ),
              ],

              // 3. Быстрые стартовые точки
              if (!_isSearchingAddress) ...[
                Padding(
                  padding: const EdgeInsets.only(top: 4, bottom: 4),
                  child: Text(
                    'Быстрые стартовые точки:',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: AppPalette.of(context).textPrimary,
                    ),
                  ),
                ),
                // Пункт "Моё местоположение"
                Builder(
                  builder: (context) {
                    final locProvider = Provider.of<LocationProvider?>(context);
                    final isLocSelected = currentStart.id == 'user_location';
                    final isLocating = locProvider?.isLocating ?? false;

                    return Container(
                      margin: const EdgeInsets.only(bottom: 4),
                      decoration: BoxDecoration(
                        color: isLocSelected
                            ? AppPalette.of(context).primary
                                  .withValues(alpha: 0.08)
                            : AppPalette.of(context).surfaceVariant
                                  .withValues(alpha: 0.4),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                          color: isLocSelected
                              ? AppPalette.of(context).primary
                              : Colors.transparent,
                          width: 1.5,
                        ),
                      ),
                      child: Material(
                        color: Colors.transparent,
                        child: ListTile(
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 0,
                          ),
                          leading: CircleAvatar(
                            radius: 16,
                            backgroundColor: isLocSelected
                                ? AppPalette.of(context).primary
                                : AppPalette.of(context).surfaceVariant,
                            child: isLocating
                                ? const SizedBox(
                                    width: 16,
                                    height: 16,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                      color: Colors.white,
                                    ),
                                  )
                                : Icon(
                                    Icons.my_location,
                                    size: 18,
                                    color: isLocSelected
                                        ? Colors.white
                                        : AppPalette.of(context).primary,
                                  ),
                          ),
                          title: Wrap(
                            crossAxisAlignment: WrapCrossAlignment.center,
                            spacing: 6,
                            runSpacing: 4,
                            children: [
                              Text(
                                AppStrings.myLocation,
                                style: TextStyle(
                                  fontSize: 13,
                                  fontWeight: isLocSelected
                                      ? FontWeight.bold
                                      : FontWeight.w600,
                                  color: isLocSelected
                                      ? AppPalette.of(context).primary
                                      : AppPalette.of(context).textPrimary,
                                ),
                              ),
                              Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 6,
                                  vertical: 2,
                                ),
                                decoration: BoxDecoration(
                                  color: AppPalette.of(context).primary
                                      .withValues(alpha: 0.15),
                                  borderRadius: BorderRadius.circular(6),
                                ),
                                child: Text(
                                  'GPS',
                                  style: TextStyle(
                                    fontSize: 10,
                                    fontWeight: FontWeight.bold,
                                    color: AppPalette.of(context).primary,
                                  ),
                                ),
                              ),
                            ],
                          ),
                          subtitle: Text(
                            locProvider?.isLocating == true
                                ? 'Определяем актуальное местоположение…'
                                : locProvider?.lastKnownLocation?.isCached ==
                                      true
                                ? 'Последняя известная позиция; запросим новую'
                                : 'Получить снимок позиции устройства',
                            style: TextStyle(
                              fontSize: 11,
                              color: AppPalette.of(context).textSecondary,
                            ),
                          ),
                          trailing: isLocSelected
                              ? Icon(
                                  Icons.check_circle,
                                  color: AppPalette.of(context).primary,
                                  size: 20,
                                )
                              : (isLocating
                                    ? null
                                    : const Icon(
                                        Icons.arrow_forward_ios,
                                        size: 12,
                                      )),
                          onTap: isLocating
                              ? null
                              : () async {
                                  final provider =
                                      Provider.of<LocationProvider?>(
                                        context,
                                        listen: false,
                                      );
                                  if (provider == null) return;
                                  final routing = context
                                      .read<RoutingProvider>();
                                  final startRevision = routing.startRevision;
                                  final snapshot = await provider
                                      .requestLocationAndLocate();
                                  if (!context.mounted ||
                                      routing.startRevision != startRevision) {
                                    return;
                                  }

                                  if (snapshot != null) {
                                    final point = provider
                                        .createUserLocationRoutePoint(snapshot);
                                    if (point == null) return;
                                    final messenger = ScaffoldMessenger.of(
                                      context,
                                    );
                                    _selectPoint(point);
                                    messenger
                                      ..clearSnackBars()
                                      ..showSnackBar(
                                        const SnackBar(
                                          content: Text(
                                            'Точка старта: Моё местоположение',
                                          ),
                                          duration: Duration(seconds: 2),
                                          behavior: SnackBarBehavior.floating,
                                        ),
                                      );
                                  } else {
                                    final error = provider.errorMessage;
                                    if (error != null) {
                                      ScaffoldMessenger.of(context)
                                        ..clearSnackBars()
                                        ..showSnackBar(
                                          SnackBar(
                                            content: Text(error),
                                            duration: const Duration(
                                              seconds: 3,
                                            ),
                                            behavior: SnackBarBehavior.floating,
                                            action: SnackBarAction(
                                              label: 'OK',
                                              onPressed: () {},
                                            ),
                                          ),
                                        );
                                    }
                                  }
                                },
                        ),
                      ),
                    );
                  },
                ),
                const SizedBox(height: 4),
                Flexible(
                  child: ListView.separated(
                    shrinkWrap: true,
                    itemCount: MapConstants.presetStartingHubs.length,
                    separatorBuilder: (_, __) =>
                        const Divider(height: 1, indent: 48),
                    itemBuilder: (context, index) {
                      final hub = MapConstants.presetStartingHubs[index];
                      final isSelected = currentStart.id == hub['id'];

                      return ListTile(
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 2,
                        ),
                        leading: CircleAvatar(
                          radius: 16,
                          backgroundColor: isSelected
                              ? AppPalette.of(context).primary
                              : AppPalette.of(context).surfaceVariant,
                          child: Icon(
                            Icons.place,
                            size: 18,
                            color: isSelected
                                ? Colors.white
                                : AppPalette.of(context).primary,
                          ),
                        ),
                        title: Text(
                          hub['title'] as String,
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: isSelected
                                ? FontWeight.bold
                                : FontWeight.w500,
                            color: isSelected
                                ? AppPalette.of(context).primary
                                : AppPalette.of(context).textPrimary,
                          ),
                        ),
                        subtitle: Text(
                          hub['subtitle'] as String,
                          style: TextStyle(
                            fontSize: 11,
                            color: AppPalette.of(context).textSecondary,
                          ),
                        ),
                        trailing: isSelected
                            ? Icon(
                                Icons.check_circle,
                                color: AppPalette.of(context).primary,
                                size: 20,
                              )
                            : null,
                        onTap: () {
                          final point = RoutePointModel(
                            id: hub['id'] as String,
                            title: hub['title'] as String,
                            subtitle: hub['subtitle'] as String,
                            latitude: hub['lat'] as double,
                            longitude: hub['lon'] as double,
                            isPreset: true,
                          );
                          _selectPoint(point);

                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                              content: Text('Точка старта: ${point.title}'),
                              duration: const Duration(seconds: 2),
                              behavior: SnackBarBehavior.floating,
                            ),
                          );
                        },
                      );
                    },
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text(
            'Закрыть',
            style: TextStyle(fontWeight: FontWeight.w600),
          ),
        ),
      ],
    );
  }
}
