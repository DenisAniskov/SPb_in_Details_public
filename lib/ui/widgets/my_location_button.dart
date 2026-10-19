import 'package:flutter/material.dart';
import 'package:smart_navigator_spb/core/constants/app_colors.dart';

/// The production map control; no coordinate source or routing lives here.
class MyLocationButton extends StatelessWidget {
  const MyLocationButton({
    super.key,
    required this.isLocating,
    required this.onPressed,
  });
  final bool isLocating;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => FloatingActionButton(
    heroTag: 'myLocation',
    tooltip: isLocating ? 'Определяем местоположение' : 'Моё местоположение',
    backgroundColor: AppPalette.of(context).surface,
    foregroundColor: AppPalette.of(context).primary,
    onPressed: isLocating ? null : onPressed,
    child: isLocating
        ? const SizedBox(
            width: 22,
            height: 22,
            child: CircularProgressIndicator(strokeWidth: 2),
          )
        : const Icon(Icons.my_location),
  );
}
