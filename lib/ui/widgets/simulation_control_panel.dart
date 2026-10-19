import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:smart_navigator_spb/core/config/simulator_gate.dart';
import 'package:smart_navigator_spb/core/utils/route_projection_utils.dart';
import 'package:smart_navigator_spb/data/models/live_navigation_state.dart';
import 'package:smart_navigator_spb/data/models/pedestrian_route_model.dart';
import 'package:smart_navigator_spb/providers/navigation_provider.dart';
import 'package:smart_navigator_spb/providers/routing_provider.dart';
import 'package:smart_navigator_spb/ui/controllers/simulation_controller.dart';

/// Debug-only developer panel driving the navigation simulator.
///
/// Rendered exclusively when [NavigationSimulatorGate.enabled] — a debug
/// build started with `--dart-define=NAVIGATION_SIMULATOR=true`. The panel
/// operates the existing Phase C4 engine through its public API only.
class SimulationControlPanel extends StatelessWidget {
  const SimulationControlPanel({super.key, required this.controller});

  final SimulationController controller;

  @override
  Widget build(BuildContext context) {
    // Defense in depth: even if miswired, the panel cannot appear outside
    // the opt-in debug simulator mode.
    if (!NavigationSimulatorGate.enabled) return const SizedBox.shrink();
    // The controller is the panel's primary listenable: pause/start, seek
    // and injection feedback arrive through its notifications.
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final nav = context.watch<NavigationProvider>();
        final routing = context.watch<RoutingProvider>();
        final palette = Theme.of(context).colorScheme;

        final hasScenario = controller.scenarioRoute != null ||
            nav.state.route != null ||
            routing.currentRoute != null;

        return _panelBody(context, controller, nav, routing, palette,
            hasScenario);
      },
    );
  }

  Widget _panelBody(
    BuildContext context,
    SimulationController controller,
    NavigationProvider nav,
    RoutingProvider routing,
    ColorScheme palette,
    bool hasScenario,
  ) {
    return Container(
      decoration: BoxDecoration(
        color: palette.surfaceContainerHighest,
        border: Border(top: BorderSide(color: palette.outline)),
      ),
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            _simulationBanner(),
            const SizedBox(height: 8),
            _transportControls(context, controller, nav, routing, hasScenario),
            const SizedBox(height: 8),
            _paceControls(context, controller),
            const SizedBox(height: 8),
            _statusLine(context, controller),
            if (hasScenario) ...[
              const SizedBox(height: 8),
              _SeekControls(controller: controller),
              const SizedBox(height: 8),
              _injectionControls(context, controller, nav),
            ],
          ],
        ),
      ),
    );
  }

  Widget _simulationBanner() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 10),
      decoration: BoxDecoration(
        color: Colors.amber.shade800,
        borderRadius: BorderRadius.circular(8),
      ),
      child: const Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.science, size: 16, color: Colors.white),
          SizedBox(width: 6),
          Text(
            'РЕЖИМ СИМУЛЯЦИИ',
            style: TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.bold,
              fontSize: 13,
              letterSpacing: 1.2,
            ),
          ),
        ],
      ),
    );
  }

  Widget _transportControls(
    BuildContext context,
    SimulationController controller,
    NavigationProvider nav,
    RoutingProvider routing,
    bool hasScenario,
  ) {
    // A session route wins; otherwise the sim starts on the planned route.
    void startSimulation() {
      if (nav.state.route != null) {
        controller.start();
        return;
      }
      final planned = routing.currentRoute;
      if (planned != null) controller.startWithRoute(planned);
    }

    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        if (!controller.isRunning)
          FilledButton.icon(
            onPressed: hasScenario ? startSimulation : null,
            icon: const Icon(Icons.play_arrow, size: 18),
            label: const Text('Старт'),
          )
        else
          FilledButton.tonalIcon(
            onPressed: () => controller.pause(),
            icon: const Icon(Icons.pause, size: 18),
            label: const Text('Пауза'),
          ),
        if (!controller.isRunning && nav.state.route != null)
          FilledButton.tonalIcon(
            onPressed: () => controller.resume(),
            icon: const Icon(Icons.play_arrow, size: 18),
            label: const Text('Продолжить'),
          ),
        OutlinedButton.icon(
          onPressed: hasScenario ? () => controller.restart() : null,
          icon: const Icon(Icons.replay, size: 18),
          label: const Text('Заново'),
        ),
        OutlinedButton.icon(
          onPressed:
              nav.status == NavigationStatus.idle && !controller.isRunning
                  ? null
                  : () => controller.finish(),
          icon: const Icon(Icons.stop, size: 18),
          label: const Text('Завершить'),
        ),
      ],
    );
  }

  Widget _paceControls(BuildContext context, SimulationController controller) {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        SegmentedButton<double>(
          segments: const [
            ButtonSegment(value: 3.0, label: Text('3 км/ч')),
            ButtonSegment(value: 5.0, label: Text('5 км/ч')),
            ButtonSegment(value: 8.0, label: Text('8 км/ч')),
          ],
          selected: {controller.speedKmh},
          onSelectionChanged: (selection) =>
              controller.setSpeed(selection.first),
        ),
        SegmentedButton<double>(
          segments: const [
            ButtonSegment(value: 1.0, label: Text('×1')),
            ButtonSegment(value: 5.0, label: Text('×5')),
            ButtonSegment(value: 20.0, label: Text('×20')),
          ],
          selected: {controller.playbackRate},
          onSelectionChanged: (selection) =>
              controller.setPlaybackRate(selection.first),
        ),
      ],
    );
  }

  Widget _statusLine(BuildContext context, SimulationController controller) {
    final distance = controller.currentDistanceMeters;
    final legLength = controller.legLengthMeters;
    final elapsed = controller.simulatedElapsed;
    String two(int value) => value.toString().padLeft(2, '0');
    final timeLabel = '${two(elapsed.inMinutes)}:${two(elapsed.inSeconds % 60)}';
    return Text(
      'Симуляция: ${distance.round()} м из ${legLength.round()} м участка · '
      'время: $timeLabel',
      style: TextStyle(
        fontSize: 12,
        fontFeatures: const [FontFeature.tabularFigures()],
        color: Theme.of(context).colorScheme.onSurfaceVariant,
      ),
    );
  }

  Widget _injectionControls(
    BuildContext context,
    SimulationController controller,
    NavigationProvider nav,
  ) {
    return Wrap(
      spacing: 6,
      runSpacing: 6,
      children: [
        _injectionChip(
          context,
          label: 'Потеря GPS 10 с',
          icon: Icons.gps_off,
          onPressed: () => controller.injectGpsLoss(),
        ),
        _injectionChip(
          context,
          label: 'Точность 45 м',
          icon: Icons.blur_on,
          onPressed: () => controller.injectLowAccuracy(),
        ),
        _injectionChip(
          context,
          label: 'Устаревший фикс',
          icon: Icons.history,
          onPressed: () => controller.injectStaleFix(),
        ),
        _injectionChip(
          context,
          label: 'Скачок +120 м',
          icon: Icons.open_in_full,
          onPressed: () => controller.jumpWalker(),
        ),
        _injectionChip(
          context,
          label: 'Отклонение 80 м',
          icon: Icons.call_missed_outgoing,
          onPressed: () => controller.injectDeviation(),
        ),
        _injectionChip(
          context,
          label: 'Вернуться на маршрут',
          icon: Icons.undo,
          onPressed:
              controller.hasDeviation ? () => controller.returnToRoute() : null,
        ),
        _injectionChip(
          context,
          label: nav.state.isPaused ? 'Возобновить (пауза ОС)' : 'Пауза (ОС)',
          icon: Icons.pause_presentation,
          onPressed: nav.state.isPaused
              ? () => nav.resumeNavigation()
              : nav.isActive
                  ? () => nav.pauseNavigation()
                  : null,
        ),
      ],
    );
  }

  Widget _injectionChip(
    BuildContext context, {
    required String label,
    required IconData icon,
    VoidCallback? onPressed,
  }) {
    return ActionChip(
      avatar: Icon(icon, size: 16),
      label: Text(label, style: const TextStyle(fontSize: 11.5)),
      visualDensity: VisualDensity.compact,
      onPressed: onPressed,
    );
  }
}

/// Leg selector and position slider. Every seek REBUILDS the session through
/// the engine's public APIs (see [SimulationController.seekToLeg]) — backward
/// movement never rewinds accepted progress, it restarts the scenario.
class _SeekControls extends StatefulWidget {
  const _SeekControls({required this.controller});

  final SimulationController controller;

  @override
  State<_SeekControls> createState() => _SeekControlsState();
}

class _SeekControlsState extends State<_SeekControls> {
  double? _dragValueMeters;

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    final route = controller.scenarioRoute;
    final legs = route?.legs ?? const <RouteLegModel>[];
    final legCount = legs.length;
    if (legCount == 0) return const SizedBox.shrink();
    final legIndex =
        controller.simulatedLegIndex.clamp(0, legCount - 1);
    final legLength =
        RouteProjectionUtils.polylineLengthMeters(legs[legIndex].geometryPoints);
    final clampedLength = legLength <= 0 ? 1.0 : legLength;
    final sliderValue =
        (_dragValueMeters ?? controller.currentDistanceMeters)
            .clamp(0.0, clampedLength);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(
              'Участок:',
              style: TextStyle(
                fontSize: 12,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: DropdownButton<int>(
                isDense: true,
                value: legIndex,
                items: [
                  for (var i = 0; i < legCount; i++)
                    DropdownMenuItem(
                      value: i,
                      child: Text(
                        '${i + 1} → ${legs[i].toTitle}',
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 12),
                      ),
                    ),
                ],
                onChanged: (value) {
                  if (value == null) return;
                  setState(() => _dragValueMeters = null);
                  controller.seekToLeg(value);
                },
              ),
            ),
          ],
        ),
        Row(
          children: [
            Text(
              'Позиция: ${sliderValue.round()} м',
              style: TextStyle(
                fontSize: 12,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
            Expanded(
              child: Slider(
                min: 0,
                max: clampedLength,
                value: sliderValue,
                divisions: legLength <= 1 ? null : legLength.round(),
                onChanged: (value) => setState(() => _dragValueMeters = value),
              ),
            ),
            TextButton(
              onPressed: () {
                final target = _dragValueMeters;
                setState(() => _dragValueMeters = null);
                controller.seekToLeg(
                  legIndex,
                  distanceMeters: target ?? controller.currentDistanceMeters,
                );
              },
              child: const Text('Перейти', style: TextStyle(fontSize: 12)),
            ),
          ],
        ),
      ],
    );
  }
}
