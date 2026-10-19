import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:smart_navigator_spb/core/constants/app_strings.dart';
import 'package:smart_navigator_spb/providers/guest_experience_provider.dart';

/// Explicit choice made on the introduction screen. The first launch consumes
/// it through [GuestLaunchGate]; reopening the introduction from settings
/// returns it as the Navigator result so the map handles the same choice.
enum OnboardingAction { startSmartWalk, showMap }

class GuestOnboardingScreen extends StatefulWidget {
  const GuestOnboardingScreen({
    super.key,
    this.firstLaunch = false,
    this.onStartWalk,
  });

  /// At startup Back is an explicit skip. When opened from settings it pops
  /// normally, without changing the underlying navigation session.
  final bool firstLaunch;

  /// First-launch only: records the guest's intent so the map can open the
  /// existing Smart Walk wizard once, after the screen is ready. Reopening the
  /// introduction from settings instead returns
  /// [OnboardingAction.startSmartWalk] to the caller and never triggers this
  /// callback.
  final VoidCallback? onStartWalk;

  @override
  State<GuestOnboardingScreen> createState() => _GuestOnboardingScreenState();
}

class _GuestOnboardingScreenState extends State<GuestOnboardingScreen> {
  bool _saving = false;

  Future<void> _finish(OnboardingAction action) async {
    if (_saving) return;
    setState(() => _saving = true);
    // The intent must be recorded BEFORE completion notifies the launch gate:
    // the gate then rebuilds directly into the map and still sees the request.
    if (widget.firstLaunch && action == OnboardingAction.startSmartWalk) {
      widget.onStartWalk?.call();
    }
    try {
      // The provider records storage failures itself. The catch is defensive:
      // an unexpected error must not leave both actions disabled forever.
      await context.read<GuestExperienceProvider>().completeOnboarding();
    } catch (_) {
      // The chosen transition still happens exactly once below.
    }
    if (!mounted) return;
    if (widget.firstLaunch) {
      setState(() => _saving = false);
    } else {
      // Reopened from settings: return the explicit choice so settings can
      // close itself and the map can act on it. System/AppBar Back pops with
      // null instead and therefore never starts Smart Walk.
      Navigator.of(context).pop(action);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return PopScope(
      canPop: !widget.firstLaunch,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop && widget.firstLaunch) _finish(OnboardingAction.showMap);
      },
      child: Scaffold(
        appBar: AppBar(
          automaticallyImplyLeading: !widget.firstLaunch,
          title: const Text('Знакомство'),
        ),
        body: SafeArea(
          top: false,
          child: ListView(
            padding: const EdgeInsets.all(20),
            children: [
              Icon(Icons.explore_outlined, size: 56, color: theme.primaryColor),
              const SizedBox(height: 16),
              Text(AppStrings.appTitle, style: theme.textTheme.headlineSmall),
              const SizedBox(height: 8),
              const Text('Ваш путеводитель по Санкт-Петербургу.'),
              const SizedBox(height: 20),
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: theme.colorScheme.primaryContainer,
                  borderRadius: BorderRadius.circular(16),
                ),
                child: DefaultTextStyle.merge(
                  style: TextStyle(color: theme.colorScheme.onPrimaryContainer),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Санкт-Петербург открыт каждому!',
                        style: theme.textTheme.titleLarge?.copyWith(
                          color: theme.colorScheme.onPrimaryContainer,
                        ),
                      ),
                      const SizedBox(height: 12),
                      const Text(
                        '${AppStrings.appTitle} создан для жителей и гостей '
                        'города. Открывайте достопримечательности, стройте '
                        'прогулки и пользуйтесь навигацией без регистрации '
                        'и создания аккаунта.',
                      ),
                      const SizedBox(height: 12),
                      const Text(
                        'Избранные места и предпочтения сохраняются на вашем '
                        'устройстве. Вы сами выбираете, когда использовать '
                        'геолокацию и дополнительные оценки маршрута.',
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 20),
              const _IntroductionItem(
                icon: Icons.place_outlined,
                title: 'Откройте город',
                body:
                    'Находите достопримечательности в каталоге и поиске, '
                    'выбирайте категории и сохраняйте места в избранное.',
              ),
              const _IntroductionItem(
                icon: Icons.directions_walk,
                title: 'Соберите пешеходную прогулку',
                body:
                    'Smart Walk подберёт места по интересам и времени, Scenic '
                    'Walk предложит живописный путь, а Quiet Engine — вариант '
                    'дальше от автомобильных дорог. Любой выбор остаётся за вами.',
              ),
              const _IntroductionItem(
                icon: Icons.info_outline,
                title: 'Учитывайте ограничения оценок',
                body:
                    'Тень, мокрые участки, пыльца и близость автомобильных '
                    'дорог — модельные оценки с ограничениями и неполными '
                    'данными. Они не гарантируют безопасность, фактическую '
                    'погоду или уровень шума на маршруте.',
              ),
              const _IntroductionItem(
                icon: Icons.lock_outline,
                title: 'Данные остаются у вас',
                body:
                    'Телефон и email не нужны. Каталог, карты, маршруты и '
                    'погодные оценки используют сеть, а избранное и '
                    'настройки хранятся локально на этом устройстве.',
              ),
              const Text(
                'Во время знакомства геолокация не запрашивается. '
                'Повторно открыть знакомство можно в настройках.',
              ),
              const SizedBox(height: 20),
              FilledButton.icon(
                onPressed: _saving
                    ? null
                    : () => _finish(OnboardingAction.startSmartWalk),
                icon: const Icon(Icons.auto_awesome),
                label: const Text('Подобрать прогулку'),
              ),
              const SizedBox(height: 8),
              OutlinedButton.icon(
                onPressed: _saving
                    ? null
                    : () => _finish(OnboardingAction.showMap),
                icon: const Icon(Icons.map_outlined),
                label: const Text('Перейти к карте'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _IntroductionItem extends StatelessWidget {
  const _IntroductionItem({
    required this.icon,
    required this.title,
    required this.body,
  });

  final IconData icon;
  final String title;
  final String body;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 20),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, color: Theme.of(context).colorScheme.primary),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 4),
              Text(body),
            ],
          ),
        ),
      ],
    ),
  );
}
