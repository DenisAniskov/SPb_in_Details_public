import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:smart_navigator_spb/providers/guest_experience_provider.dart';
import 'package:smart_navigator_spb/ui/widgets/place_preview_card.dart';

class FavoritesScreen extends StatefulWidget {
  const FavoritesScreen({super.key});

  @override
  State<FavoritesScreen> createState() => _FavoritesScreenState();
}

class _FavoritesScreenState extends State<FavoritesScreen> {
  GuestExperienceProvider? _guest;
  Map<String, FavoriteResolution> _resolvedByIdentity = const {};
  int _favoritesRevision = -1;
  int _generation = 0;
  bool _resolving = false;
  bool _loading = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final guest = context.read<GuestExperienceProvider>();
    if (identical(guest, _guest)) return;
    _guest?.removeListener(_favoritesChanged);
    _guest = guest;
    ++_generation;
    _resolving = false;
    _favoritesRevision = guest.favoritesRevision;
    _resolvedByIdentity = const {};
    _loading = guest.favorites.isNotEmpty;
    guest.addListener(_favoritesChanged);
    unawaited(_resolveFavorites());
  }

  void _favoritesChanged() {
    final guest = _guest!;
    if (guest.favoritesRevision == _favoritesRevision) return;
    _favoritesRevision = guest.favoritesRevision;
    setState(() {
      // Remove every previously resolved card even when remove/re-add restored
      // the same final identities before the next frame.
      _resolvedByIdentity = const {};
      _loading = guest.favorites.isNotEmpty;
    });
    // The provider can change legacy identities while resolving this request.
    // Wait for its result before deciding whether another catalog read is
    // necessary. Composition changes are coalesced into one subsequent read.
    if (!_resolving) unawaited(_resolveFavorites());
  }

  Future<void> _resolveFavorites() async {
    if (_resolving) return;
    final guest = _guest!;
    _resolving = true;
    final generation = ++_generation;
    final revision = guest.favoritesRevision;
    final references = guest.favorites;
    final requestedIdentities = references.map((item) => item.identity).toSet();
    final resolutions = await guest.resolveFavorites();
    if (!mounted || generation != _generation || !identical(guest, _guest)) {
      return;
    }
    _resolving = false;
    final identities = guest.favorites.map((item) => item.identity).toSet();
    final byIdentity = {
      for (final result in resolutions) result.reference.identity: result,
    };
    final superseded = resolutions.any(
      (result) =>
          result.unavailableReason == FavoriteUnavailableReason.superseded,
    );
    final coversCurrent =
        byIdentity.length == resolutions.length &&
        byIdentity.length == identities.length &&
        identities.every(byIdentity.containsKey);
    final migrated =
        guest.favoritesRevision == revision + 1 &&
        references.any((item) => item.catalogKey == null) &&
        !requestedIdentities.every(identities.contains) &&
        references
            .where((item) => item.catalogKey != null)
            .every((item) => identities.contains(item.identity));
    // A successful legacy -> catalog_key migration returns the new identity
    // set from this same request. Reuse it without a second catalog read.
    // Superseded results are never accepted, including remove/re-add with an
    // identical final identity set.
    if (coversCurrent &&
        !superseded &&
        (guest.favoritesRevision == revision || migrated)) {
      setState(() {
        _resolvedByIdentity = byIdentity;
        _loading = false;
      });
    } else if (guest.favoritesRevision != revision || superseded) {
      unawaited(_resolveFavorites());
    } else {
      setState(() {
        _resolvedByIdentity = const {};
        _loading = false;
      });
    }
  }

  void _retry() {
    if (_resolving) return;
    setState(() {
      _resolvedByIdentity = const {};
      _loading = _guest!.favorites.isNotEmpty;
    });
    unawaited(_resolveFavorites());
  }

  @override
  void dispose() {
    _guest?.removeListener(_favoritesChanged);
    ++_generation;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final guest = context.watch<GuestExperienceProvider>();
    return Scaffold(
      appBar: AppBar(
        title: const Text('Избранное'),
        actions: [
          IconButton(
            tooltip: 'Обновить избранное',
            onPressed: _retry,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: SafeArea(
        top: false,
        child: guest.favorites.isEmpty
            ? _FavoritesMessage(
                text: guest.storageError == null
                    ? 'Пока нет избранных мест. Нажмите сердечко в карточке '
                          'места, чтобы сохранить его здесь.'
                    : 'Не удалось сохранить или восстановить избранное. '
                          'Сохранённые места могут быть недоступны. '
                          'Изменения могут не сохраниться после перезапуска.',
              )
            : _loading
            ? const Center(
                child: CircularProgressIndicator(
                  semanticsLabel: 'Обновление избранного',
                ),
              )
            : ListView(
                // Saved labels identify references only. They are never
                // displayed as a current address, description or coordinate.
                padding: const EdgeInsets.all(16),
                children: [
                  if (guest.storageError != null)
                    const Padding(
                      padding: EdgeInsets.only(bottom: 12),
                      child: Text(
                        'Не удалось сохранить или восстановить избранное. '
                        'Изменения могут не сохраниться после перезапуска.',
                      ),
                    ),
                  const Text(
                    'Сведения проверяются по текущему каталогу. '
                    'Открытие карточки не строит маршрут.',
                  ),
                  const SizedBox(height: 12),
                  for (final reference in guest.favorites)
                    Builder(
                      builder: (context) {
                        final place =
                            _resolvedByIdentity[reference.identity]?.place;
                        return Card(
                          key: ValueKey(reference.identity),
                          child: ListTile(
                            contentPadding: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 8,
                            ),
                            title: Text(place?.title ?? reference.label),
                            subtitle: Text(
                              place?.category.displayName ??
                                  'Не удалось обновить сведения о месте',
                            ),
                            leading: Icon(
                              place == null
                                  ? Icons.cloud_off_outlined
                                  : Icons.favorite,
                            ),
                            trailing: IconButton(
                              tooltip:
                                  'Удалить «${reference.label}» из избранного',
                              onPressed: () => guest.removeFavorite(reference),
                              icon: const Icon(Icons.delete_outline),
                            ),
                            onTap: place == null
                                ? null
                                : () => Navigator.of(context).push(
                                    MaterialPageRoute<void>(
                                      builder: (previewContext) => Scaffold(
                                        appBar: AppBar(
                                          title: const Text('Место'),
                                        ),
                                        body: SafeArea(
                                          top: false,
                                          child: SingleChildScrollView(
                                            child: PlacePreviewCard(
                                              place: place,
                                              onClose: () =>
                                                  Navigator.of(previewContext)
                                                      .pop(),
                                            ),
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                          ),
                        );
                      },
                    ),
                  TextButton.icon(
                    onPressed: _retry,
                    icon: const Icon(Icons.refresh),
                    label: const Text('Обновить сведения'),
                  ),
                ],
              ),
      ),
    );
  }
}

class _FavoritesMessage extends StatelessWidget {
  const _FavoritesMessage({required this.text});
  final String text;

  @override
  Widget build(BuildContext context) => SingleChildScrollView(
    padding: const EdgeInsets.all(24),
    child: Text(text),
  );
}
