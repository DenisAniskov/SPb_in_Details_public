import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:smart_navigator_spb/core/constants/app_colors.dart';
import 'package:smart_navigator_spb/core/constants/app_strings.dart';
import 'package:smart_navigator_spb/data/models/place_model.dart';
import 'package:smart_navigator_spb/providers/places_provider.dart';
import 'package:smart_navigator_spb/providers/search_provider.dart';

class CategoryFilterChips extends StatelessWidget {
  const CategoryFilterChips({super.key});

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<PlacesProvider>();
    final palette = AppPalette.of(context);

    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      physics: const BouncingScrollPhysics(),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        children: [
          // Кнопка "Необычные места"
          FilterChip(
            selected: provider.isUnusualOnly,
            avatar: Icon(
              Icons.auto_awesome,
              size: 16,
              color: provider.isUnusualOnly
                  ? palette.onSolid
                  : palette.unusualBadge,
            ),
            label: const Text(
              AppStrings.filterUnusual,
              style: TextStyle(fontWeight: FontWeight.w600),
            ),
            selectedColor: palette.unusualBadge,
            checkmarkColor: palette.onSolid,
            labelStyle: TextStyle(
              color: provider.isUnusualOnly
                  ? palette.onSolid
                  : palette.unusualBadge,
            ),
            backgroundColor: palette.surface,
            side: BorderSide(
              color: provider.isUnusualOnly
                  ? palette.unusualBadge
                  : palette.border,
              width: 1.5,
            ),
            onSelected: (_) => provider.toggleUnusualOnly(),
          ),
          const SizedBox(width: 8),

          // Разделитель
          Container(
            height: 24,
            width: 1,
            color: palette.divider,
            margin: const EdgeInsets.symmetric(horizontal: 4),
          ),
          const SizedBox(width: 4),

          // Категории интересов
          ...PlaceCategoryEnum.values.map((category) {
            final isSelected = provider.selectedCategories.contains(category);
            return Padding(
              padding: const EdgeInsets.only(right: 8),
              child: FilterChip(
                selected: isSelected,
                avatar: Icon(
                  category.icon,
                  size: 16,
                  color: isSelected
                      ? Colors.white
                      : palette.category(category.color),
                ),
                label: Text(category.displayName),
                // Сырые насыщенные цвета категорий одинаковы в обеих темах,
                // белый текст читается на них в светлом и тёмном оформлении.
                selectedColor: category.color,
                checkmarkColor: Colors.white,
                labelStyle: TextStyle(
                  color: isSelected ? Colors.white : palette.textPrimary,
                  fontWeight: isSelected ? FontWeight.w600 : FontWeight.w500,
                ),
                backgroundColor: palette.surface,
                side: BorderSide(
                  color: isSelected
                      ? category.color
                      : palette.border,
                  width: 1.2,
                ),
                onSelected: (_) => provider.toggleCategory(category),
              ),
            );
          }),

          // Кнопка сброса если есть активные фильтры
          if (provider.selectedCategories.isNotEmpty || provider.isUnusualOnly)
            Padding(
              padding: const EdgeInsets.only(left: 4),
              child: ActionChip(
                avatar: Icon(
                  Icons.close,
                  size: 16,
                  color: palette.error,
                ),
                label: Text(
                  'Сброс',
                  style: TextStyle(
                    color: palette.error,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                backgroundColor: palette.surface,
                side: BorderSide(
                  color: palette.error,
                  width: 1.2,
                ),
                onPressed: () {
                  provider.clearFilters();
                  Provider.of<SearchProvider?>(
                    context,
                    listen: false,
                  )?.clearSearch();
                },
              ),
            ),
        ],
      ),
    );
  }
}
