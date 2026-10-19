import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:smart_navigator_spb/core/constants/app_colors.dart';
import 'package:smart_navigator_spb/data/models/place_model.dart';
import 'package:smart_navigator_spb/data/models/route_point_model.dart';
import 'package:smart_navigator_spb/data/models/scenic_walk_model.dart';
import 'package:smart_navigator_spb/data/models/smart_walk_preset.dart';
import 'package:smart_navigator_spb/data/repositories/places_repository.dart';
import 'package:smart_navigator_spb/providers/guest_experience_provider.dart';
import 'package:smart_navigator_spb/providers/historical_content_provider.dart';
import 'package:smart_navigator_spb/providers/navigation_provider.dart';
import 'package:smart_navigator_spb/providers/pollen_assessment_provider.dart';
import 'package:smart_navigator_spb/providers/puddle_assessment_provider.dart';
import 'package:smart_navigator_spb/providers/quiet_assessment_provider.dart';
import 'package:smart_navigator_spb/providers/routing_provider.dart';
import 'package:smart_navigator_spb/services/pollen_analysis_service.dart';
import 'package:smart_navigator_spb/services/puddle_analysis_service.dart';
import 'package:smart_navigator_spb/services/quiet_analysis_service.dart';
import 'package:smart_navigator_spb/services/virtual_shade_clock.dart';
import 'package:smart_navigator_spb/ui/controllers/guided_walk_controller.dart';
import 'package:smart_navigator_spb/ui/controllers/simulation_controller.dart';
import 'package:smart_navigator_spb/ui/controllers/guided_walk_environment_coordinator.dart';
import 'package:smart_navigator_spb/ui/screens/main_map_screen.dart';
import 'package:smart_navigator_spb/ui/widgets/guided_walk_report_section.dart';
import 'package:smart_navigator_spb/ui/widgets/start_point_selector_dialog.dart';
import 'package:smart_navigator_spb/ui/widgets/walk_planner_sheet.dart';

class SmartWalkWizardSheet extends StatefulWidget {
  const SmartWalkWizardSheet({
    super.key,
    this.repository,
    this.controller,
    this.chooseMapStart,
  });
  final PlacesRepository? repository;
  final GuidedWalkController? controller;
  final Future<RoutePointModel?> Function()? chooseMapStart;
  @override
  State<SmartWalkWizardSheet> createState() => _SmartWalkWizardSheetState();
}

class _SmartWalkWizardSheetState extends State<SmartWalkWizardSheet> {
  late final PlacesRepository _repository;
  late final GuidedWalkController _controller;
  final ScrollController _scroll = ScrollController();
  GuidedWalkStep? _lastStep;

  @override
  void initState() {
    super.initState();
    _repository =
        widget.repository ??
        context.read<PlacesRepository?>() ??
        PlacesRepository();
    _controller =
        widget.controller ??
        GuidedWalkController(
          source: context.read<RoutingProvider>(),
          repository: _repository,
          guest: context.read<GuestExperienceProvider?>(),
          navigation: context.read<NavigationProvider?>(),
          puddleService: context.read<BasePuddleAnalysisService?>(),
          pollenService: context.read<BasePollenAnalysisService?>(),
          quietService: context.read<BaseQuietAnalysisService?>(),
          mainPuddle: context.read<PuddleAssessmentProvider?>(),
          mainPollen: context.read<PollenAssessmentProvider?>(),
          mainQuiet: context.read<QuietAssessmentProvider?>(),
          mainClock: context.read<VirtualShadeClock?>(),
          simulation: context.read<SimulationController?>(),
        );
    _controller.addListener(_changed);
  }

  void _changed() {
    if (!mounted) return;
    if (_lastStep != _controller.step) {
      _lastStep = _controller.step;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_scroll.hasClients) _scroll.jumpTo(0);
      });
    }
    setState(() {});
  }

  @override
  void dispose() {
    _controller.removeListener(_changed);
    if (widget.controller == null) _controller.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _close() {
    _controller.cancel();
    Navigator.of(context).pop();
  }

  Future<void> _chooseStart() async {
    if (_controller.locked) return;
    await showDialog<void>(
      context: context,
      builder: (_) => ChangeNotifierProvider<RoutingProvider>.value(
        value: _controller.routing,
        child: StartPointSelectorDialog(
          currentStart: _controller.routing.startPoint,
          onSelected: (point) {
            if (!_controller.locked) _controller.routing.setStartPoint(point);
          },
          onChooseMap: () async {
            final point =
                await (widget.chooseMapStart?.call() ??
                    chooseGuidedWalkStartOnMap(context));
            if (mounted && !_controller.locked && point != null) {
              _controller.routing.setStartPoint(point);
            }
          },
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    final step = controller.step;
    final locked = controller.locked;
    final palette = AppPalette.of(context);
    final title = switch (step) {
      GuidedWalkStep.start => 'Точка отправления',
      GuidedWalkStep.mode => 'Как построить прогулку?',
      GuidedWalkStep.duration => 'Продолжительность прогулки',
      GuidedWalkStep.interests => 'Ваши интересы',
      GuidedWalkStep.proposal =>
        controller.mode == GuidedWalkMode.manual
            ? 'Ваш маршрут'
            : 'Предварительный маршрут',
      GuidedWalkStep.scenic => 'Какой маршрут вам больше подходит?',
      GuidedWalkStep.environment => 'Условия прогулки',
      GuidedWalkStep.report => 'Ваша прогулка готова!',
    };
    return PopScope(
      canPop: step == GuidedWalkStep.start || controller.locked,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) controller.back();
      },
      child: Material(
        color: palette.surface,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
        child: SafeArea(
          top: false,
          child: SingleChildScrollView(
            controller: _scroll,
            padding: EdgeInsets.fromLTRB(
              16,
              12,
              16,
              20 + MediaQuery.viewInsetsOf(context).bottom,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    const Expanded(
                      child: Text(
                        'Прогулка по Петербургу',
                        style: TextStyle(fontWeight: FontWeight.bold),
                      ),
                    ),
                    IconButton(
                      tooltip: 'Закрыть мастер',
                      onPressed: _close,
                      icon: const Icon(Icons.close),
                    ),
                  ],
                ),
                Semantics(
                  label:
                      'Шаг ${step.index + 1} из ${GuidedWalkStep.values.length}. $title',
                  child: LinearProgressIndicator(
                    value: (step.index + 1) / GuidedWalkStep.values.length,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  'Шаг ${step.index + 1} из ${GuidedWalkStep.values.length}',
                  style: TextStyle(color: palette.textSecondary),
                ),
                const SizedBox(height: 8),
                Semantics(
                  header: true,
                  child: Text(
                    title,
                    style: const TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                if (locked)
                  const Text(
                    'Чтобы изменить прогулку, сначала завершите навигацию.',
                  ),
                if (controller.error case final error?)
                  Semantics(
                    liveRegion: true,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      child: Text(
                        error,
                        style: TextStyle(color: palette.error),
                      ),
                    ),
                  ),
                ChangeNotifierProvider<RoutingProvider>.value(
                  value: controller.routing,
                  child: _content(context, step),
                ),
                if (controller.busy) ...[
                  const SizedBox(height: 12),
                  const LinearProgressIndicator(),
                  Semantics(liveRegion: true, child: Text(_progressText())),
                ],
                const SizedBox(height: 16),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    if (step != GuidedWalkStep.start)
                      OutlinedButton.icon(
                        onPressed: controller.back,
                        icon: const Icon(Icons.arrow_back),
                        label: const Text('Назад'),
                      ),
                    if (_continueLabel(step) case final label?)
                      FilledButton(
                        onPressed:
                            locked ||
                                controller.busy ||
                                (step == GuidedWalkStep.scenic &&
                                    !controller.canContinueScenic)
                            ? null
                            : () => _continue(step),
                        child: Text(label),
                      ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _content(BuildContext context, GuidedWalkStep step) {
    final controller = _controller;
    switch (step) {
      case GuidedWalkStep.start:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              'Добро пожаловать! Давайте подберём прогулку по Санкт-Петербургу. Для начала выберите, откуда хотите отправиться.',
            ),
            const SizedBox(height: 12),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.trip_origin),
              title: Text(controller.routing.startPoint.title),
            ),
            OutlinedButton.icon(
              onPressed: controller.locked ? null : _chooseStart,
              icon: const Icon(Icons.edit_location_alt_outlined),
              label: const Text('Выбрать точку отправления'),
            ),
            const Text(
              'Моё местоположение · Дворцовая площадь · Точка на карте · Поиск адреса или достопримечательности',
            ),
            const SizedBox(height: 8),
            const Text(
              'Местоположение запрашивается только после вашего выбора. Регистрация не нужна.',
            ),
          ],
        );
      case GuidedWalkStep.mode:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              'Как вы хотите исследовать город? Мы можем подобрать интересные места за вас или построить маршрут по вашим точкам.',
            ),
            _choice(
              'Умная прогулка',
              'Подберём места по интересам и времени',
              controller.mode == GuidedWalkMode.smart,
              () => controller.setMode(GuidedWalkMode.smart),
            ),
            _choice(
              'Собственный маршрут',
              'Выберите до шести мест и их порядок',
              controller.mode == GuidedWalkMode.manual,
              () => controller.setMode(GuidedWalkMode.manual),
            ),
          ],
        );
      case GuidedWalkStep.duration:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text('Сколько времени вы хотите посвятить прогулке?'),
            for (final preset in SmartWalkPreset.values)
              _choice(
                preset.label,
                '${preset.approximateDuration}. ${preset.description}',
                controller.preset == preset,
                () => controller.setPreset(preset),
              ),
            const Text(
              'Продолжительность включает ходьбу и редакторское время осмотра объектов. Время ходьбы проверим по MapKit.',
            ),
          ],
        );
      case GuidedWalkStep.interests:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              'Что вам больше всего интересно в Санкт-Петербурге? Выберите одну или несколько тем.',
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final category in PlaceCategoryEnum.values)
                  FilterChip(
                    label: Text(category.displayName),
                    selected: controller.categories.contains(category),
                    onSelected: controller.locked
                        ? null
                        : (_) => controller.toggleCategory(category),
                  ),
              ],
            ),
            const Text('Если ничего не выбрано, подберём места по всем темам.'),
            const SizedBox(height: 16),
            const Text(
              'Хотите, чтобы мы предложили необычные и менее известные места?',
            ),
            _choice(
              'Да, мне интересно открывать новое',
              '',
              controller.preferUnusual,
              () => controller.setPreferUnusual(true),
            ),
            _choice(
              'Нет, лучше известные достопримечательности',
              '',
              !controller.preferUnusual,
              () => controller.setPreferUnusual(false),
            ),
          ],
        );
      case GuidedWalkStep.proposal:
        if (controller.mode == GuidedWalkMode.manual) {
          return WalkPlannerSheet(
            embedded: true,
            disabled: controller.busy || controller.locked,
            busy: controller.busy,
            repository: _repository,
            onContinue: controller.buildPreview,
          );
        }
        return _proposal(context);
      case GuidedWalkStep.scenic:
        return _scenic();
      case GuidedWalkStep.environment:
        return _environment();
      case GuidedWalkStep.report:
        return GuidedWalkReportSection(
          routing: controller.routing,
          environment: controller.environment,
        );
    }
  }

  Widget _proposal(BuildContext context) {
    final controller = _controller;
    final proposal = controller.proposal;
    final history = context.watch<HistoricalContentProvider?>();
    if (proposal != null && history != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !identical(controller.proposal, proposal)) return;
        for (final item in proposal.items) {
          history.ensureLoaded(item.place);
        }
      });
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (proposal != null) ...[
          Text(
            proposal.items.isEmpty
                ? 'Прогулка пока не подобрана'
                : 'Предварительный вариант прогулки',
            style: const TextStyle(fontWeight: FontWeight.bold),
          ),
          Text(proposal.resultMessage),
          const SizedBox(height: 8),
          Text(
            'Геометрическая оценка до MapKit. Расстояние по прямым: ~${(proposal.estimatedTotalDistanceMeters / 1000).toStringAsFixed(1)} км · '
            'ходьба ~${(proposal.estimatedWalkingDurationSeconds / 60).round()} мин · осмотр ~${proposal.estimatedVisitDurationMinutes} мин · всего ~${proposal.estimatedTotalDurationMinutes} мин',
          ),
          Text(
            'Мест: ${proposal.items.length}. Реальный пешеходный путь ещё не проверен.',
          ),
          for (var i = 0; i < proposal.items.length; i++) ...[
            const SizedBox(height: 10),
            Text(
              '${i + 1}. ${proposal.items[i].place.title}',
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
            Text('Осмотр ~${proposal.items[i].visitDurationMinutes} мин'),
            if (history
                    ?.contentFor(proposal.items[i].place.id)
                    ?.shortHistoricalSummary
                case final String summary when summary.isNotEmpty)
              Text(summary),
            for (final reason in proposal.items[i].reasons) Text(reason),
          ],
        ],
        const SizedBox(height: 12),
        if (proposal?.items.isNotEmpty == true) ...[
          FilledButton(
            onPressed: controller.busy || controller.locked
                ? null
                : controller.buildPreview,
            child: Text(
              controller.busy
                  ? 'Строим пешеходный маршрут…'
                  : 'Построить прогулку',
            ),
          ),
          const SizedBox(height: 6),
          const Text(
            'Проверим настоящий пешеходный маршрут, расстояние и время по карте.',
            style: TextStyle(fontSize: 12),
          ),
        ],
        OutlinedButton(
          onPressed: controller.busy || controller.locked
              ? null
              : () => controller.generateProposal(another: true),
          child: Text(
            proposal == null
                ? 'Подобрать прогулку'
                : 'Подобрать другой вариант',
          ),
        ),
        TextButton(
          onPressed: controller.locked ? null : controller.back,
          child: const Text('Изменить интересы'),
        ),
        TextButton(
          onPressed: controller.locked
              ? null
              : () => controller.setMode(GuidedWalkMode.manual),
          child: const Text('Выбрать места самостоятельно'),
        ),
      ],
    );
  }

  Widget _scenic() {
    final controller = _controller;
    final routing = controller.routing;
    final normal = routing.verifiedNormalRoute;
    final scenic = routing.verifiedScenicRoute;
    final comparison = routing.routeComparison;
    final quiet = routing.verifiedQuietRoute;
    final quietDecision = routing.quietDecision;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text(
          'Какой маршрут вам больше подходит? Выбор всегда явный: '
          'приложение не подменяет маршрут само.',
        ),
        const SizedBox(height: 8),
        if (normal != null)
          Text(
            'Обычный: ${normal.distanceMeters.round()} м · '
            '${(normal.durationSeconds / 60).ceil()} мин ходьбы. '
            'Подтверждено MapKit.',
          ),
        const SizedBox(height: 8),
        if (!routing.scenicChecked) ...[
          const Text(
            'Проверим, есть ли подходящий живописный путь. Доступность '
            'подтвердим по реальной геометрии маршрута.',
          ),
          FilledButton.icon(
            onPressed: controller.busy || controller.locked
                ? null
                : controller.checkScenic,
            icon: const Icon(Icons.landscape_outlined),
            label: const Text('Проверить живописный вариант'),
          ),
        ] else if (scenic != null && comparison != null) ...[
          const Text(
            'Мы нашли живописный вариант прогулки! Он проходит по '
            'подтверждённым красивым городским пространствам.',
          ),
          Text(
            'Живописный: ${scenic.distanceMeters.round()} м · '
            '${(scenic.durationSeconds / 60).ceil()} мин ходьбы',
          ),
          Text(
            'Разница: ${comparison.extraDistanceMeters.round()} м · '
            '${(comparison.extraWalkingSeconds / 60).ceil()} мин',
          ),
          for (final stage in scenic.legs.map((leg) => leg.scenic).nonNulls)
            Text(
              '${stage.featureNames.join(', ')}. '
              '${stage.evidence == ScenicEvidenceLevel.verifiedOnPath ? 'Подтверждено по геометрии пути' : 'Подтверждено прохождение рядом'}. '
              'Покрытие ${(stage.coverageShare * 100).round()}%',
            ),
        ] else ...[
          const Text(
            'Для этой прогулки мы не нашли подходящий живописный вариант. '
            'Обычный пешеходный маршрут готов.',
          ),
          if (routing.scenicFallbackMessage case final fallback?)
            Text(fallback),
        ],
        const SizedBox(height: 8),
        const Divider(),
        const SizedBox(height: 8),
        const Text(
          'Мы можем поискать путь вдали от крупных автомобильных дорог. '
          'Оценка основана на карте дорожной сети и не заменяет измерение шума.',
        ),
        if (!routing.quietAvailable)
          const Text('Проверка более тихого варианта недоступна в этой сборке.')
        else if (!routing.quietChecked) ...[
          FilledButton.icon(
            onPressed: controller.busy || controller.locked
                ? null
                : controller.checkQuiet,
            icon: const Icon(Icons.volume_off_outlined),
            label: const Text('Проверить более тихий вариант'),
          ),
        ] else if (quiet != null &&
            quietDecision != null &&
            quietDecision.offersAlternative) ...[
          const Text(
            'Мы нашли более тихий вариант с сопоставимым покрытием данных.',
          ),
          Text(
            'Более тихий: ${quiet.distanceMeters.round()} м · '
            '${(quiet.durationSeconds / 60).ceil()} мин ходьбы',
          ),
          Text(
            'Дополнительно: +${quietDecision.extraDistanceMeters.round()} м · '
            '+${(quietDecision.extraWalkingSeconds / 60).ceil()} мин',
          ),
          Text(
            'Относительный прокси: '
            '${quietDecision.normalAnalysis.roadNoiseExposureIndex!.toStringAsFixed(2)} → '
            '${quietDecision.candidateAnalysis!.roadNoiseExposureIndex!.toStringAsFixed(2)}. '
            'Покрытие: ${(quietDecision.candidateCoverageShare! * 100).round()}%.',
          ),
          const Text(
            'Это не дБ и не измерение шума: оценка показывает близость '
            'маршрута к автомобильным дорогам по данным OSM.',
          ),
        ] else ...[
          Text(
            quietDecision?.fallbackText ??
                routing.quietFailure?.message ??
                'Подтверждённого более тихого варианта не нашлось. '
                    'Обычный маршрут сохранён.',
          ),
        ],
        const SizedBox(height: 8),
        _choice(
          'Обычный маршрут',
          'Оставить обычный пешеходный путь',
          controller.routeChoiceConfirmed &&
              controller.selectedKind == WalkKind.normal,
          () => controller.selectRoute(WalkKind.normal),
        ),
        if (scenic != null)
          _choice(
            'Живописный маршрут',
            'Выбрать подтверждённый живописный вариант',
            controller.routeChoiceConfirmed &&
                controller.selectedKind == WalkKind.scenic,
            () => controller.selectRoute(WalkKind.scenic),
          ),
        if (quiet != null && quietDecision?.offersAlternative == true)
          _choice(
            'Более тихий маршрут',
            'Выбрать подтверждённый вариант с меньшим относительным '
                'воздействием дорожной сети',
            controller.routeChoiceConfirmed &&
                controller.selectedKind == WalkKind.quiet,
            () => controller.selectRoute(WalkKind.quiet),
          ),
      ],
    );
  }

  Widget _environment() {
    final controller = _controller;
    final environment = controller.environment;
    final departure = environment?.selectedDeparture;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text(
          'Хотите узнать, сколько тени будет на прогулке, где возможны мокрые '
          'участки, какие данные о пыльце доступны и насколько маршрут '
          'предположительно близок к автомобильным дорогам?',
        ),
        TextButton.icon(
          onPressed: controller.busy || controller.locked || environment == null
              ? null
              : _pickDeparture,
          icon: const Icon(Icons.schedule),
          label: Text(
            departure == null
                ? 'Выбрать время начала прогулки'
                : 'Начало: ${_formatInstant(departure)}',
          ),
        ),
        const Text(
          'Все четыре оценки относятся ко всей выбранной прогулке и одному '
          'времени начала. Тишина — статическая оценка дорожной сети, а не '
          'прогноз шума по часам. Некоторые значения могут быть недоступны.',
        ),
        FilledButton(
          onPressed: controller.busy || controller.locked
              ? null
              : controller.assessEnvironment,
          child: const Text('Проверить условия прогулки'),
        ),
        TextButton(
          onPressed: controller.locked ? null : controller.skipEnvironment,
          child: Text(
            controller.busy
                ? 'Отменить проверку и пропустить'
                : 'Пропустить экологический анализ',
          ),
        ),
      ],
    );
  }

  Future<void> _pickDeparture() async {
    final environment = _controller.environment;
    if (environment == null) return;
    final initial = environment.selectedDeparture ?? DateTime.now();
    final date = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: initial.subtract(const Duration(days: 1)),
      lastDate: initial.add(const Duration(days: 7)),
    );
    if (!mounted || date == null) return;
    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(initial),
    );
    if (!mounted || time == null) return;
    environment.selectDeparture(
      DateTime(date.year, date.month, date.day, time.hour, time.minute),
    );
  }

  Widget _choice(
    String label,
    String description,
    bool selected,
    VoidCallback onTap,
  ) {
    final disabled = _controller.locked;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Semantics(
        selected: selected,
        button: true,
        enabled: !disabled,
        child: OutlinedButton(
          style: OutlinedButton.styleFrom(
            alignment: Alignment.centerLeft,
            padding: const EdgeInsets.all(12),
          ),
          onPressed: disabled ? null : onTap,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                selected
                    ? Icons.radio_button_checked
                    : Icons.radio_button_unchecked,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      label,
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                    if (description.isNotEmpty) Text(description),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  String? _continueLabel(GuidedWalkStep step) => switch (step) {
    GuidedWalkStep.start ||
    GuidedWalkStep.mode ||
    GuidedWalkStep.duration => 'Продолжить',
    GuidedWalkStep.interests => 'Сформировать прогулку',
    GuidedWalkStep.scenic => 'Продолжить с выбранным маршрутом',
    GuidedWalkStep.report => 'Показать маршрут на карте',
    _ => null,
  };
  void _continue(GuidedWalkStep step) {
    if (step == GuidedWalkStep.interests) {
      _controller.generateProposal();
    } else if (step == GuidedWalkStep.report) {
      if (_controller.showMap()) Navigator.of(context).pop();
    } else {
      _controller.next();
    }
  }

  String _progressText() => switch (_controller.environment?.phase) {
    GuidedWalkEnvironmentPhase.shade => 'Проверяем тень',
    GuidedWalkEnvironmentPhase.puddle => 'Анализируем влажные участки',
    GuidedWalkEnvironmentPhase.pollen => 'Получаем сведения о пыльце',
    GuidedWalkEnvironmentPhase.preparingReport =>
      'Подготавливаем итоговый отчёт',
    _ =>
      _controller.step == GuidedWalkStep.proposal
          ? 'Строим пешеходный маршрут…'
          : _controller.step == GuidedWalkStep.scenic
          ? 'Проверяем живописный путь'
          : 'Подготавливаем маршрут',
  };
}

String _formatInstant(DateTime value) {
  String two(int number) => '$number'.padLeft(2, '0');
  return '${two(value.day)}.${two(value.month)}.${value.year} ${two(value.hour)}:${two(value.minute)}';
}
