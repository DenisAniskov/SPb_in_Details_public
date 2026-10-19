import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:smart_navigator_spb/data/models/context_recommendation_model.dart';
import 'package:smart_navigator_spb/data/models/place_model.dart';
import 'package:smart_navigator_spb/providers/assistant_provider.dart';
import 'package:smart_navigator_spb/providers/guest_experience_provider.dart';
import 'package:smart_navigator_spb/providers/context_recommendation_provider.dart';
import 'package:smart_navigator_spb/providers/navigation_provider.dart';
import 'package:smart_navigator_spb/providers/theme_provider.dart';
import 'package:smart_navigator_spb/providers/tts_provider.dart';
import 'package:smart_navigator_spb/services/voice/tts_service.dart';
import 'package:smart_navigator_spb/services/voice/voice_engine_service.dart';
import 'package:smart_navigator_spb/services/voice/voice_search_controller.dart';
import 'package:smart_navigator_spb/services/voice/voice_settings.dart';
import 'package:smart_navigator_spb/ui/screens/guest_onboarding_screen.dart';
import 'package:smart_navigator_spb/ui/widgets/about_app_section.dart';
import 'package:smart_navigator_spb/ui/widgets/voice_consent_dialog.dart';

class GuestSettingsScreen extends StatefulWidget {
  const GuestSettingsScreen({super.key});

  @override
  State<GuestSettingsScreen> createState() => _GuestSettingsScreenState();
}

class _GuestSettingsScreenState extends State<GuestSettingsScreen> {
  bool _openingOnboarding = false;

  Future<void> _repeatOnboarding() async {
    if (_openingOnboarding) return;
    setState(() => _openingOnboarding = true);
    final action = await Navigator.of(context).push<OnboardingAction>(
      MaterialPageRoute<OnboardingAction>(
        builder: (_) => const GuestOnboardingScreen(),
      ),
    );
    if (!mounted) return;
    if (action == null) {
      // Back from the introduction returns to these settings unchanged.
      setState(() => _openingOnboarding = false);
      return;
    }
    // Close settings too and let the map act on the guest's explicit choice.
    Navigator.of(context).pop(action);
  }

  Future<void> _confirmRevokeAssistantConsent(
    AssistantProvider assistant,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Отозвать согласие?'),
        content: const Text(
          'Новые вопросы не будут отправляться через OpenRouter. История '
          'беседы в этой сессии будет очищена. Карта, поиск и навигация '
          'продолжат работать без ИИ.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Отозвать'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await assistant.revokeConsent();
    if (!mounted) return;
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      const SnackBar(
        content: Text('Согласие отозвано. Новые вопросы не отправляются.'),
      ),
    );
  }

  List<Widget> _voiceConsentTiles(
    VoiceSearchController voice,
    VoiceEngineSnapshot snapshot,
  ) {
    final consent = snapshot.onlineConsent;
    return [
      ListTile(
        contentPadding: EdgeInsets.zero,
        leading: Icon(
          consent ? Icons.check_circle_outline : Icons.info_outline,
        ),
        title: Text(
          consent
              ? 'Согласие на распознавание получено'
              : 'Согласие не получено',
        ),
        subtitle: Text(
          consent
              ? 'Голосовой поиск разрешён. Системная служба Android может '
                    'использовать интернет.'
              : 'Голосовой поиск не запускается. Текстовый поиск доступен '
                    'всегда.',
        ),
      ),
      if (consent)
        OutlinedButton.icon(
          onPressed: () => _revokeOnlineConsent(voice),
          icon: const Icon(Icons.link_off, size: 18),
          label: const Text('Отозвать согласие'),
        )
      else
        FilledButton.icon(
          onPressed: () => _grantOnlineConsent(voice),
          icon: const Icon(Icons.mic_none, size: 18),
          label: const Text('Разрешить голосовой поиск'),
        ),
      const SizedBox(height: 8),
      ListTile(
        contentPadding: EdgeInsets.zero,
        leading: Icon(
          snapshot.supported
              ? Icons.record_voice_over_outlined
              : Icons.error_outline,
        ),
        title: Text(
          snapshot.supported
              ? 'Системное распознавание доступно'
              : 'Системное распознавание недоступно',
        ),
        subtitle: Text(
          snapshot.supported
              ? 'Микрофон запрашивается Android только при запуске '
                    'распознавания.'
              : snapshot.reason ??
                    'Текстовый поиск продолжает работать без микрофона.',
        ),
      ),
    ];
  }

  Future<void> _grantOnlineConsent(VoiceSearchController voice) async {
    final accepted = await showVoiceConsentDialog(context);
    if (!accepted || !mounted) return;
    final saved = await voice.setOnlineConsent(true);
    if (!saved && mounted) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        const SnackBar(content: Text('Не удалось сохранить согласие.')),
      );
    }
  }

  Future<void> _revokeOnlineConsent(VoiceSearchController voice) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Отозвать согласие?'),
        content: const Text(
          'Новые голосовые сессии не будут запускаться. Если распознавание '
          'уже идёт, микрофон будет остановлен. Текстовый поиск продолжит '
          'работать.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Отозвать'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    final saved = await voice.setOnlineConsent(false);
    if (!saved && mounted) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        const SnackBar(content: Text('Не удалось отозвать согласие.')),
      );
    }
  }

  void _showVoiceError(BuildContext context, TtsProvider tts) {
    final messenger = ScaffoldMessenger.maybeOf(context);
    messenger?.showSnackBar(
      SnackBar(
        content: Text(
          tts.errorMessage ?? 'Озвучивание недоступно на этом устройстве.',
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final guest = context.watch<GuestExperienceProvider>();
    final locked = context.watch<NavigationProvider?>()?.locksPlanning ?? false;
    final recommendations = context.watch<ContextRecommendationProvider?>();
    final tts = context.watch<TtsProvider?>();
    final voice = context.watch<VoiceSearchController?>();
    final assistant = context.watch<AssistantProvider?>();
    final appearance = context.watch<ThemeProvider?>();
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Настройки')),
      body: SafeArea(
        top: false,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Text('Ваши настройки', style: theme.textTheme.titleLarge),
            const SizedBox(height: 8),
            const Text(
              'Приложение работает без аккаунтов. Избранное, интересы '
              'и настройки сохраняются на этом устройстве.',
            ),
            const SizedBox(height: 8),
            const Text(
              'Данные не синхронизируются автоматически между устройствами '
              'и могут быть потеряны при очистке данных приложения.',
            ),
            const SizedBox(height: 8),
            const Text(
              'Каталог, карты, маршрутизация и погодные источники могут '
              'требовать сетевых обращений. Это не меняет локальное '
              'хранение избранного и настроек.',
            ),
            if (guest.storageError != null) ...[
              const SizedBox(height: 12),
              Semantics(
                liveRegion: true,
                child: const Text(
                  'Не удалось сохранить или восстановить локальные данные. '
                  'Текущие изменения могут не сохраниться после перезапуска.',
                ),
              ),
            ],
            if (appearance != null) ...[
              const SizedBox(height: 20),
              Text('Оформление', style: theme.textTheme.titleMedium),
              const SizedBox(height: 4),
              const Text(
                'Тема применяется сразу, без перезапуска. По умолчанию '
                'используется системная тема устройства.',
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 4,
                children: [
                  for (final preference in AppThemePreference.values)
                    ChoiceChip(
                      label: Text(preference.label),
                      selected: appearance.preference == preference,
                      onSelected: (_) => appearance.setPreference(preference),
                    ),
                ],
              ),
              if (appearance.persistenceFailed)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(
                    'Не удалось сохранить выбор темы на устройстве. Он '
                    'действует до перезапуска приложения.',
                    style: TextStyle(color: theme.colorScheme.error),
                  ),
                ),
            ],
            const SizedBox(height: 24),
            Text('Интересующие категории', style: theme.textTheme.titleMedium),
            const SizedBox(height: 4),
            const Text('Если ничего не выбрано, доступны все категории.'),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 4,
              children: [
                for (final category in PlaceCategoryEnum.values)
                  FilterChip(
                    avatar: Icon(category.icon, size: 18),
                    label: Text(category.displayName),
                    selected: guest.categories.contains(category),
                    onSelected: locked
                        ? null
                        : (selected) {
                            final categories = {...guest.categories};
                            if (selected) {
                              categories.add(category);
                            } else {
                              categories.remove(category);
                            }
                            guest.setCategories(categories);
                          },
                  ),
              ],
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Предпочитать необычные места'),
              subtitle: const Text(
                'Фильтр каталога и предпочтение Smart Walk.',
              ),
              value: guest.preferUnusual,
              onChanged: locked ? null : guest.setPreferUnusual,
            ),
            const Divider(),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Показывать рекомендации'),
              subtitle: const Text(
                'Автоматическое отображение панели при наличии оценок. '
                'Настройка сохраняется между запусками.',
              ),
              value: guest.showRecommendations,
              onChanged: (visible) {
                guest.setShowRecommendations(visible);
                if (visible) recommendations?.showForCurrentWalk();
              },
            ),
            if (guest.showRecommendations &&
                recommendations != null &&
                !recommendations.panelVisible)
              TextButton.icon(
                onPressed: recommendations.showForCurrentWalk,
                icon: const Icon(Icons.visibility_outlined),
                label: const Text('Показать в текущей прогулке'),
              ),
            const SizedBox(height: 8),
            Text('Приоритет рекомендаций', style: theme.textTheme.titleMedium),
            const SizedBox(height: 8),
            Semantics(
              label: 'Приоритет рекомендаций',
              child: DropdownButton<RecommendationPreference>(
                isExpanded: true,
                value: guest.recommendationPreference,
                items: const [
                  DropdownMenuItem(
                    value: RecommendationPreference.all,
                    child: Text('Все факторы'),
                  ),
                  DropdownMenuItem(
                    value: RecommendationPreference.shade,
                    child: Text('Больше тени'),
                  ),
                  DropdownMenuItem(
                    value: RecommendationPreference.scenic,
                    child: Text('Больше живописности'),
                  ),
                ],
                onChanged: (preference) {
                  if (preference != null) {
                    guest.setRecommendationPreference(preference);
                  }
                },
              ),
            ),
            const Text(
              'Меняет порядок отображения. Оценки и маршрут не '
              'пересчитываются. Анализ запускается только вашим действием.',
            ),
            if (voice != null) ...[
              const Divider(height: 32),
              Text('Голосовой поиск', style: theme.textTheme.titleMedium),
              const SizedBox(height: 4),
              const Text(voiceSystemConsentNotice),
              const SizedBox(height: 8),
              if (voice.engineSnapshot == null)
                const ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                  title: Text('Проверяем доступность распознавания…'),
                )
              else
                ..._voiceConsentTiles(voice, voice.engineSnapshot!),
              const SizedBox(height: 4),
              const Text(
                'Согласие можно отозвать здесь в любой момент. '
                'Текстовый поиск работает и без согласия.',
              ),
            ],
            if (tts != null) ...[
              const Divider(height: 32),
              Text('Голосовые подсказки', style: theme.textTheme.titleMedium),
              const SizedBox(height: 4),
              const Text(
                'Проверенные инструкции маршрута можно слышать на этом '
                'устройстве. Озвучивание выключено по умолчанию, '
                'текстовая навигация работает всегда.',
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Озвучивать навигацию'),
                subtitle: Text(
                  tts.available
                      ? 'Русский голос системы Android. Звук можно '
                            'выключить и на экране навигации.'
                      : 'Русский голос не найден. Текстовая навигация '
                            'продолжает работать.',
                ),
                value: tts.enabled,
                onChanged: tts.ready && tts.available
                    ? (value) async {
                        final ok = await tts.setEnabled(value);
                        if (!ok && context.mounted) {
                          _showVoiceError(context, tts);
                        }
                      }
                    : null,
              ),
              if (tts.enabled) ...[
                Text('Скорость речи: ${(tts.rate * 200).round()}%'),
                Slider(
                  value: tts.rate,
                  min: VoiceSettings.minRate,
                  max: VoiceSettings.maxRate,
                  divisions: 8,
                  label: '${(tts.rate * 200).round()}%',
                  onChanged: tts.setRate,
                ),
                if (tts.voices.length > 1)
                  DropdownButton<TtsVoice?>(
                    isExpanded: true,
                    value: tts.selectedVoice,
                    items: [
                      const DropdownMenuItem<TtsVoice?>(
                        value: null,
                        child: Text('Русский голос по умолчанию'),
                      ),
                      for (final voice in tts.voices)
                        DropdownMenuItem<TtsVoice?>(
                          value: voice,
                          child: Text(
                            '${voice.name} (${voice.locale})',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                    ],
                    onChanged: tts.selectVoice,
                  ),
                const SizedBox(height: 8),
                OutlinedButton.icon(
                  onPressed: () async {
                    final ok = await tts.speakTest();
                    if (!ok && context.mounted) {
                      _showVoiceError(context, tts);
                    }
                  },
                  icon: const Icon(Icons.volume_up_outlined),
                  label: const Text('Прослушать пример'),
                ),
              ],
              if (tts.voiceNotice != null)
                Text(
                  tts.voiceNotice!,
                  style: TextStyle(color: theme.colorScheme.error),
                ),
              if (tts.errorMessage != null && tts.ready)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(
                    tts.errorMessage!,
                    style: TextStyle(color: theme.colorScheme.error),
                  ),
                ),
              const SizedBox(height: 4),
              const Text(
                'Озвучивание использует системный TTS-движок Android. '
                'Голосовые запросы и записи микрофона не сохраняются. '
                'Если одновременно включён TalkBack, навигационную речь '
                'можно отключить здесь или на экране навигации.',
              ),
            ],
            if (assistant != null) ...[
              const Divider(height: 32),
              Text('ИИ-помощник', style: theme.textTheme.titleMedium),
              const SizedBox(height: 4),
              const Text(
                'ИИ-помощник работает без аккаунта и кода доступа. Вопрос '
                'отправляется через OpenRouter стороннему поставщику модели; '
                'бесплатная модель может сохранять запросы. История беседы '
                'хранится только в памяти этой сессии.',
              ),
              const SizedBox(height: 8),
              if (assistant.consentLoading)
                const ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                  title: Text('Проверяем сохранённое согласие…'),
                )
              else ...[
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(
                    assistant.consented
                        ? Icons.check_circle_outline
                        : Icons.info_outline,
                  ),
                  title: const Text('Согласие на облачную обработку текста'),
                  subtitle: Text(
                    assistant.consented
                        ? 'Принято. Новые вопросы можно отправлять.'
                        : 'Не принято. Вопросы не отправляются. Согласие '
                              'запрашивается при первом открытии помощника.',
                  ),
                ),
                if (assistant.consented)
                  OutlinedButton.icon(
                    onPressed: () => _confirmRevokeAssistantConsent(assistant),
                    icon: const Icon(Icons.link_off),
                    label: const Text('Отозвать согласие'),
                  ),
                if (assistant.consentPersistenceFailed)
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Text(
                      'Не удалось сохранить выбор на устройстве. Он действует '
                      'до перезапуска приложения.',
                      style: TextStyle(color: theme.colorScheme.error),
                    ),
                  ),
              ],
            ],
            const SizedBox(height: 20),
            const Divider(height: 1),
            const SizedBox(height: 20),
            const AboutAppSection(),
            const SizedBox(height: 20),
            OutlinedButton.icon(
              onPressed: locked || _openingOnboarding
                  ? null
                  : _repeatOnboarding,
              icon: const Icon(Icons.explore_outlined),
              label: const Text('Повторить знакомство'),
            ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: locked ? null : guest.resetPreferences,
              icon: const Icon(Icons.restart_alt),
              label: const Text('Сбросить настройки'),
            ),
            const SizedBox(height: 8),
            const Text(
              'Сброс настроек сохраняет избранное. Удалить отдельное '
              'место можно на экране «Избранное».',
            ),
            if (locked) ...[
              const SizedBox(height: 12),
              const Text(
                'Во время навигации фильтры, сброс и повторное знакомство '
                'недоступны. Показ и приоритет рекомендаций можно менять.',
              ),
            ],
          ],
        ),
      ),
    );
  }
}
