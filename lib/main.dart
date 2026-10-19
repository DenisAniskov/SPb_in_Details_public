import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:smart_navigator_spb/core/config/app_bootstrap.dart';
import 'package:smart_navigator_spb/core/config/app_configuration.dart';
import 'package:smart_navigator_spb/core/config/simulator_gate.dart';
import 'package:smart_navigator_spb/core/constants/app_strings.dart';
import 'package:smart_navigator_spb/core/network/api_client.dart';
import 'package:smart_navigator_spb/core/theme/app_theme.dart';
import 'package:smart_navigator_spb/data/repositories/places_repository.dart';
import 'package:smart_navigator_spb/data/local/guest_local_store.dart';
import 'package:smart_navigator_spb/providers/guest_experience_provider.dart';
import 'package:smart_navigator_spb/ui/widgets/guest_launch_gate.dart';
import 'package:smart_navigator_spb/data/repositories/search_repository.dart';
import 'package:smart_navigator_spb/providers/assistant_provider.dart';
import 'package:smart_navigator_spb/providers/city_viewpoint_provider.dart';
import 'package:smart_navigator_spb/providers/context_recommendation_provider.dart';
import 'package:smart_navigator_spb/providers/historical_content_provider.dart';
import 'package:smart_navigator_spb/providers/location_provider.dart';
import 'package:smart_navigator_spb/providers/navigation_provider.dart';
import 'package:smart_navigator_spb/providers/places_provider.dart';
import 'package:smart_navigator_spb/providers/pollen_assessment_provider.dart';
import 'package:smart_navigator_spb/providers/puddle_assessment_provider.dart';
import 'package:smart_navigator_spb/providers/quiet_assessment_provider.dart';
import 'package:smart_navigator_spb/providers/routing_provider.dart';
import 'package:smart_navigator_spb/providers/search_provider.dart';
import 'package:smart_navigator_spb/providers/theme_provider.dart';
import 'package:smart_navigator_spb/providers/tts_provider.dart';
import 'package:smart_navigator_spb/services/assistant/assistant_consent_store.dart';
import 'package:smart_navigator_spb/services/assistant/assistant_service.dart';
import 'package:smart_navigator_spb/services/location_service.dart';
import 'package:smart_navigator_spb/services/voice/voice_engine_service.dart';
import 'package:smart_navigator_spb/services/voice/tts_service.dart';
import 'package:smart_navigator_spb/services/voice/voice_search_controller.dart';
import 'package:smart_navigator_spb/services/voice/voice_settings.dart';
import 'package:smart_navigator_spb/services/mapkit_service.dart';
import 'package:smart_navigator_spb/services/pollen_analysis_service.dart';
import 'package:smart_navigator_spb/services/puddle_analysis_service.dart';
import 'package:smart_navigator_spb/services/quiet_analysis_service.dart';
import 'package:smart_navigator_spb/services/shade_analysis_service.dart';
import 'package:smart_navigator_spb/services/simulated_location_source.dart';
import 'package:smart_navigator_spb/services/virtual_shade_clock.dart';
import 'package:smart_navigator_spb/ui/controllers/simulation_controller.dart';
import 'package:smart_navigator_spb/ui/screens/main_map_screen.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  try {
    final configuration = await initializeApplication();
    runApp(SmartNavigatorApp(configuration: configuration));
  } on AppConfigurationException catch (error) {
    runApp(ConfigurationErrorApp(message: error.message));
  }
}

class SmartNavigatorApp extends StatelessWidget {
  const SmartNavigatorApp({super.key, required this.configuration});

  final AppConfiguration configuration;

  @override
  Widget build(BuildContext context) {
    // Phase C4.1: the simulator replaces the device location source only
    // when a debug build was explicitly started with the simulator define.
    // Production and ordinary debug runs keep the real geolocator stack and
    // never see a simulator instance at all.
    final SimulatedLocationSource? simulatorSource =
        NavigationSimulatorGate.enabled ? SimulatedLocationSource() : null;
    return MultiProvider(
      providers: [
        Provider<ApiClient>(
          create: (_) => ApiClient(customBaseUrl: configuration.apiBaseUrl),
        ),
        // C13.2: manual appearance preference, stored separately from guest,
        // favorites, voice and AI consent. Default remains the system theme.
        ChangeNotifierProvider<ThemeProvider>(create: (_) => ThemeProvider()),
        ProxyProvider<ApiClient, PlacesRepository>(
          update: (_, client, __) => PlacesRepository(apiClient: client),
        ),
        ProxyProvider<ApiClient, SearchRepository>(
          update: (_, client, __) => SearchRepository(apiClient: client),
        ),
        // Phase C13.1: built-in AI conversation without an access code. Only
        // the accepted notice version is stored locally; the OpenRouter
        // key/model stay on the backend.
        ChangeNotifierProvider<AssistantProvider>(
          create: (ctx) => AssistantProvider(
            assistantService: BackendAssistantService(
              apiClient: ctx.read<ApiClient>(),
            ),
            consentStore: SharedPreferencesAssistantConsentStore(),
          ),
        ),
        ChangeNotifierProvider<GuestExperienceProvider>(
          create: (ctx) => GuestExperienceProvider(
            store: SharedPreferencesGuestLocalStore(),
            repository: ctx.read<PlacesRepository>(),
            catalogScope: configuration.apiBaseUrl,
          )..initialize(),
        ),
        Provider<LocationService>(create: (_) => LocationService()),
        Provider<MapKitService>(create: (_) => MapKitService()),
        ChangeNotifierProvider<LocationProvider>(
          create: (_) => LocationProvider(),
        ),
        ChangeNotifierProxyProvider<PlacesRepository, PlacesProvider>(
          create: (ctx) => PlacesProvider(
            repository: ctx.read<PlacesRepository>(),
            guest: ctx.read<GuestExperienceProvider>(),
          ),
          update: (_, repo, prev) => prev ?? PlacesProvider(repository: repo),
        ),
        // C14: transient selection of a verified public viewpoint. It is
        // shared by the place card and the map; it owns no route state.
        ChangeNotifierProvider<CityViewpointProvider>(
          create: (_) => CityViewpointProvider(),
        ),
        // Phase C6: lazy per-place historical cards with a session cache.
        ChangeNotifierProxyProvider<
          PlacesRepository,
          HistoricalContentProvider
        >(
          create: (ctx) => HistoricalContentProvider(
            repository: ctx.read<PlacesRepository>(),
          ),
          update: (_, repo, prev) =>
              prev ?? HistoricalContentProvider(repository: repo),
        ),
        ChangeNotifierProxyProvider<SearchRepository, SearchProvider>(
          create: (ctx) =>
              SearchProvider(repository: ctx.read<SearchRepository>()),
          update: (_, repo, prev) => prev ?? SearchProvider(repository: repo),
        ),
        // Phase A6.2: the shade service is built from the SAME configured
        // ApiClient as the catalog and search repositories. The single
        // instance is handed to RoutingProvider, which passes it on to its
        // ShadeRoutingEngine — no component invents its own backend URL.
        Provider<BaseShadeAnalysisService>(
          create: (ctx) =>
              BackendShadeAnalysisService(apiClient: ctx.read<ApiClient>()),
        ),
        // Phase C11: the quiet comparison and assessment share the same
        // configured ApiClient; no second Dio and no server URL invention.
        Provider<BaseQuietAnalysisService>(
          create: (ctx) =>
              BackendQuietAnalysisService(apiClient: ctx.read<ApiClient>()),
        ),
        ChangeNotifierProxyProvider4<
          LocationService,
          MapKitService,
          BaseShadeAnalysisService,
          BaseQuietAnalysisService,
          RoutingProvider
        >(
          create: (ctx) => RoutingProvider(
            locationService: ctx.read<LocationService>(),
            mapKitService: ctx.read<MapKitService>(),
            shadeAnalysisService: ctx.read<BaseShadeAnalysisService>(),
            quietAnalysisService: ctx.read<BaseQuietAnalysisService>(),
          ),
          update: (_, loc, mapkit, shade, quiet, prev) =>
              prev ??
              RoutingProvider(
                locationService: loc,
                mapKitService: mapkit,
                shadeAnalysisService: shade,
                quietAnalysisService: quiet,
              ),
        ),
        ChangeNotifierProvider<NavigationProvider>(
          create: (ctx) => NavigationProvider(
            locationService: simulatorSource,
            routingProvider: ctx.read<RoutingProvider>(),
            // Shared MapKit routing stack; rerouting reuses the same service
            // instance as planning instead of creating a second one.
            routeService: ctx.read<MapKitService>(),
          ),
        ),
        // Phase C12: local voice search. The controller owns only the
        // microphone state machine; confirmed text is handed to the existing
        // search providers by the map screen.
        ChangeNotifierProvider<VoiceSearchController>(
          create: (_) => VoiceSearchController(
            service: createProductionVoiceEngineService(),
          )..initializeEngineSettings(),
        ),
        // Voice output is a separate, default-off preference. It observes the
        // existing NavigationProvider and never owns route state.
        ChangeNotifierProxyProvider<NavigationProvider, TtsProvider>(
          create: (ctx) => TtsProvider(
            service: FlutterTtsService(),
            store: SharedPreferencesVoiceSettingsStore(),
            navigation: ctx.read<NavigationProvider>(),
          )..initialize(),
          update: (_, nav, prev) =>
              prev ??
              (TtsProvider(
                service: FlutterTtsService(),
                store: SharedPreferencesVoiceSettingsStore(),
                navigation: nav,
              )..initialize()),
        ),
        // The simulator controller is mounted only in simulator mode and
        // reuses the SAME NavigationProvider instance the app navigates with.
        if (simulatorSource != null)
          ChangeNotifierProvider<SimulationController>(
            create: (ctx) => SimulationController(
              source: simulatorSource,
              nav: ctx.read<NavigationProvider>(),
            ),
          ),
        // Phase C7.1 §15.1: the virtual shade clock exists only alongside the
        // opted-in simulator and mirrors ITS virtual time, never the device
        // clock. Shade overlays are always evaluated at the model time.
        if (simulatorSource != null)
          ChangeNotifierProvider<VirtualShadeClock>(
            create: (ctx) {
              final clock = VirtualShadeClock(
                controller: ctx.read<SimulationController>(),
              );
              // The routing provider is the only writer of shade state, so it
              // owns the clock's semantic calls (arm / markAnalyzed /
              // invalidate); without this link the clock would never be armed
              // and the virtual time would stay null.
              ctx.read<RoutingProvider>().attachShadeClock(clock);
              return clock;
            },
          ),
        // Phase C7.2: the wet-surface assessment is optional and read-only.
        // It is built from the SAME configured ApiClient as everything else
        // (no second Dio), and it observes the EXISTING RoutingProvider and
        // NavigationProvider — it never owns, re-orders or rebuilds a route,
        // and a failure leaves ordinary navigation untouched.
        Provider<BasePuddleAnalysisService>(
          create: (ctx) =>
              BackendPuddleAnalysisService(apiClient: ctx.read<ApiClient>()),
        ),
        ChangeNotifierProxyProvider3<
          RoutingProvider,
          NavigationProvider,
          BasePuddleAnalysisService,
          PuddleAssessmentProvider
        >(
          create: (ctx) => PuddleAssessmentProvider(
            ctx.read<BasePuddleAnalysisService>(),
            routing: ctx.read<RoutingProvider>(),
            navigation: ctx.read<NavigationProvider>(),
            // Present only in the opted-in simulator: the assessment then
            // follows the SAME virtual timeline as the shade overlay.
            clock: ctx.read<VirtualShadeClock?>(),
          ),
          update: (ctx, routing, navigation, service, prev) =>
              prev ??
              PuddleAssessmentProvider(
                service,
                routing: routing,
                navigation: navigation,
                clock: ctx.read<VirtualShadeClock?>(),
              ),
        ),
        // Phase C7.3: the pollen assessment is optional and read-only too. It
        // reuses the SAME configured ApiClient and observes the SAME existing
        // providers — it never owns, re-orders or rebuilds a route, and a
        // failure leaves ordinary navigation untouched. Pollen is not
        // combined with shade, puddle or scenic scoring in any way.
        Provider<BasePollenAnalysisService>(
          create: (ctx) =>
              BackendPollenAnalysisService(apiClient: ctx.read<ApiClient>()),
        ),
        ChangeNotifierProxyProvider3<
          RoutingProvider,
          NavigationProvider,
          BasePollenAnalysisService,
          PollenAssessmentProvider
        >(
          create: (ctx) => PollenAssessmentProvider(
            ctx.read<BasePollenAnalysisService>(),
            routing: ctx.read<RoutingProvider>(),
            navigation: ctx.read<NavigationProvider>(),
            // Present only in the opted-in simulator: the assessment then
            // follows the SAME virtual timeline as the shade overlay.
            clock: ctx.read<VirtualShadeClock?>(),
          ),
          update: (ctx, routing, navigation, service, prev) =>
              prev ??
              PollenAssessmentProvider(
                service,
                routing: routing,
                navigation: navigation,
                clock: ctx.read<VirtualShadeClock?>(),
              ),
        ),
        // Phase C11: the quiet assessment observes the SAME route and clock as
        // shade/puddle/pollen. It is read-only and never starts navigation.
        ChangeNotifierProxyProvider3<
          RoutingProvider,
          NavigationProvider,
          BaseQuietAnalysisService,
          QuietAssessmentProvider
        >(
          create: (ctx) => QuietAssessmentProvider(
            ctx.read<BaseQuietAnalysisService>(),
            routing: ctx.read<RoutingProvider>(),
            navigation: ctx.read<NavigationProvider>(),
            clock: ctx.read<VirtualShadeClock?>(),
          ),
          update: (ctx, routing, navigation, service, prev) =>
              prev ??
              QuietAssessmentProvider(
                service,
                routing: routing,
                navigation: navigation,
                clock: ctx.read<VirtualShadeClock?>(),
              ),
        ),
        // Phase C7.4: the recommendations panel is a DERIVED view. It owns no
        // route, no assessment and no timer — it reads the CURRENT state of the
        // providers above on every build, which is why an invalidated or
        // discarded analysis cannot leave a stale recommendation behind. It
        // starts nothing on its own; the only action it offers re-runs an
        // existing assessment on an explicit user gesture.
        ChangeNotifierProvider<ContextRecommendationProvider>(
          create: (ctx) => ContextRecommendationProvider(
            routing: ctx.read<RoutingProvider>(),
            navigation: ctx.read<NavigationProvider>(),
            puddle: ctx.read<PuddleAssessmentProvider?>(),
            pollen: ctx.read<PollenAssessmentProvider?>(),
            clock: ctx.read<VirtualShadeClock?>(),
            guest: ctx.read<GuestExperienceProvider>(),
          ),
        ),
      ],
      child: Consumer<ThemeProvider>(
        builder: (context, themeProvider, _) => MaterialApp(
          title: AppStrings.appTitle,
          theme: AppTheme.lightTheme,
          darkTheme: AppTheme.darkTheme,
          themeMode: themeProvider.themeMode,
          // The appearance choice applies immediately, without a cross-fade.
          themeAnimationDuration: Duration.zero,
          debugShowCheckedModeBanner: false,
          home: GuestLaunchGate(homeBuilder: (_) => const MainMapScreen()),
        ),
      ),
    );
  }
}

/// A configuration failure stays visible instead of crashing before runApp.
class ConfigurationErrorApp extends StatelessWidget {
  const ConfigurationErrorApp({super.key, required this.message});
  final String message;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      theme: AppTheme.lightTheme,
      darkTheme: AppTheme.darkTheme,
      debugShowCheckedModeBanner: false,
      home: Scaffold(
        appBar: AppBar(title: const Text('Ошибка конфигурации')),
        body: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: SelectableText(message),
        ),
      ),
    );
  }
}
