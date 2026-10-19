import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:smart_navigator_spb/data/models/place_model.dart';
import 'package:smart_navigator_spb/providers/guest_experience_provider.dart';

class FavoriteButton extends StatelessWidget {
  const FavoriteButton({super.key, required this.place});

  final PlaceModel place;

  @override
  Widget build(BuildContext context) {
    final guest = context.watch<GuestExperienceProvider?>();
    if (guest == null) return const SizedBox.shrink();
    final selected = guest.isFavorite(place);
    final label = selected
        ? 'Удалить «${place.title}» из избранного'
        : 'Добавить «${place.title}» в избранное';
    Future<void> toggle() async {
      await guest.toggleFavorite(place);
      if (!context.mounted || guest.storageError == null) return;
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        const SnackBar(
          content: Text(
            'Не удалось сохранить избранное на устройстве. '
            'Изменение доступно до закрытия приложения.',
          ),
        ),
      );
    }

    return Semantics(
      label: label,
      button: true,
      toggled: selected,
      onTap: toggle,
      excludeSemantics: true,
      child: IconButton(
        tooltip: label,
        constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
        visualDensity: VisualDensity.standard,
        onPressed: toggle,
        icon: Icon(
          selected ? Icons.favorite : Icons.favorite_border,
          color: selected ? Theme.of(context).colorScheme.primary : null,
        ),
      ),
    );
  }
}
