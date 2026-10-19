import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:smart_navigator_spb/core/config/app_configuration.dart';
import 'package:smart_navigator_spb/core/constants/api_constants.dart';

// Test credentials are synthetic values with no access to any service.
const _localKey = 'synthetic-local-mapkit-key';
const _explicitKey = 'synthetic-explicit-mapkit-key';
const _localSettings = {
  'MAPKIT_API_KEY': _localKey,
  'API_BASE_URL': 'http://192.168.1.100:8000',
  'APP_ENV': 'development',
};
const _releaseSettings = {
  'MAPKIT_API_KEY': _explicitKey,
  'API_BASE_URL': 'https://backend.example.test',
  'APP_ENV': 'production',
};

TypeMatcher<AppConfigurationException> _configurationError(String setting) =>
    isA<AppConfigurationException>().having(
      (error) => error.message,
      'diagnostic names the setting',
      contains(setting),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('configuration precedence and validation', () {
    test(
      'each explicit define overrides only its corresponding local value',
      () {
        final keyOverride = AppConfiguration.resolve(
          defines: const {'MAPKIT_API_KEY': _explicitKey},
          localValues: _localSettings,
          isDebug: true,
        );
        expect(keyOverride.mapKitApiKey, _explicitKey);
        expect(keyOverride.apiBaseUrl, 'http://192.168.1.100:8000/api/v1');
        expect(keyOverride.appEnv, 'development');

        final urlOverride = AppConfiguration.resolve(
          defines: const {
            'API_BASE_URL': 'https://remote.example.test/api/v1/',
          },
          localValues: _localSettings,
          isDebug: true,
        );
        expect(urlOverride.mapKitApiKey, _localKey);
        expect(urlOverride.apiBaseUrl, 'https://remote.example.test/api/v1');
        expect(urlOverride.appEnv, 'development');

        final environmentOverride = AppConfiguration.resolve(
          defines: const {'APP_ENV': 'staging'},
          localValues: _localSettings,
          isDebug: true,
        );
        expect(environmentOverride.mapKitApiKey, _localKey);
        expect(
          environmentOverride.apiBaseUrl,
          'http://192.168.1.100:8000/api/v1',
        );
        expect(environmentOverride.appEnv, 'staging');
      },
    );

    for (final setting in _localSettings.keys) {
      test(
        'an explicitly empty $setting cannot fall back to local settings',
        () {
          expect(
            () => AppConfiguration.resolve(
              defines: {setting: ''},
              localValues: _localSettings,
              isDebug: true,
            ),
            throwsA(_configurationError(setting)),
          );
        },
      );
    }

    test('debug defaults supply the backend and environment, never a key', () {
      final configuration = AppConfiguration.resolve(
        defines: const {'MAPKIT_API_KEY': _explicitKey},
        isDebug: true,
        developmentApiBaseUrl: 'http://10.0.2.2:8000',
      );
      expect(configuration.apiBaseUrl, 'http://10.0.2.2:8000/api/v1');
      expect(configuration.appEnv, 'development');
      expect(
        () => AppConfiguration.resolve(defines: const {}, isDebug: true),
        throwsA(_configurationError('MAPKIT_API_KEY')),
      );
    });

    for (final key in [
      '',
      '   ',
      'YOUR_MAPKIT_KEY',
      'your_mapkit_key',
      'REPLACE_MAPKIT_KEY',
      'CHANGEME',
      'PLACEHOLDER',
      'TODO',
      '<mapkit-key>',
      'two words',
      'synthetic\u0000key',
    ]) {
      test(
        'missing, placeholder or malformed client key is rejected: $key',
        () {
          expect(
            () => AppConfiguration.resolve(
              defines: {'MAPKIT_API_KEY': key},
              isDebug: true,
            ),
            throwsA(_configurationError('MAPKIT_API_KEY')),
          );
        },
      );
    }

    test('unknown or empty APP_ENV fails with an actionable diagnostic', () {
      for (final environment in ['', 'debug', 'Production', 'prod']) {
        expect(
          () => AppConfiguration.resolve(
            defines: {'APP_ENV': environment},
            localValues: _localSettings,
            isDebug: true,
          ),
          throwsA(_configurationError('APP_ENV')),
        );
      }
    });

    test(
      'validation diagnostics do not include supplied credentials or URLs',
      () {
        const secret = 'synthetic-sensitive-key';
        const url = 'https://private-user:$secret@backend.example.test';
        try {
          AppConfiguration.resolve(
            defines: const {
              'MAPKIT_API_KEY': secret,
              'API_BASE_URL': url,
              'APP_ENV': 'invalid-sensitive-environment',
            },
            isDebug: true,
          );
          fail('Invalid URL and environment must be rejected.');
        } on AppConfigurationException catch (error) {
          expect(error.message, contains('API_BASE_URL'));
          expect(error.message, contains('APP_ENV'));
          expect(error.toString(), isNot(contains(secret)));
          expect(error.toString(), isNot(contains(url)));
          expect(
            error.toString(),
            isNot(contains('invalid-sensitive-environment')),
          );
        }
      },
    );
  });

  group('backend URL normalization', () {
    const expected = {
      'http://10.0.2.2:8000': 'http://10.0.2.2:8000/api/v1',
      'http://192.168.1.100:8000/': 'http://192.168.1.100:8000/api/v1',
      'https://backend.example.test/api/v1':
          'https://backend.example.test/api/v1',
      'https://backend.example.test/api/v1///':
          'https://backend.example.test/api/v1',
      'https://backend.example.test/smartnav/':
          'https://backend.example.test/smartnav/api/v1',
      'https://backend.example.test/smartnav/api/v1/':
          'https://backend.example.test/smartnav/api/v1',
      'http://[::1]:8000': 'http://[::1]:8000/api/v1',
      'https://steadfast-curiosity-production-f250.up.railway.app':
          'https://steadfast-curiosity-production-f250.up.railway.app/api/v1',
      'https://steadfast-curiosity-production-f250.up.railway.app/':
          'https://steadfast-curiosity-production-f250.up.railway.app/api/v1',
      'https://steadfast-curiosity-production-f250.up.railway.app/api/v1':
          'https://steadfast-curiosity-production-f250.up.railway.app/api/v1',
    };
    for (final entry in expected.entries) {
      test('normalizes ${entry.key} without duplicating the API prefix', () {
        expect(
          AppConfiguration.normalizeApiBaseUrl(entry.key, requireHttps: false),
          entry.value,
        );
      });
    }

    const invalidUrls = {
      'relative URL': '/api/v1',
      'unsupported scheme': 'ftp://backend.example.test',
      'missing host': 'http:///api/v1',
      'credentials': 'https://user:synthetic-password@backend.example.test',
      'username': 'https://user@backend.example.test',
      'query': 'https://backend.example.test?token=synthetic-key',
      'empty query': 'https://backend.example.test?',
      'fragment': 'https://backend.example.test#synthetic-key',
      'empty fragment': 'https://backend.example.test#',
      'zero port': 'http://backend.example.test:0',
      'out of range port': 'http://backend.example.test:65536',
      'nonnumeric port': 'http://backend.example.test:bad',
      'space in host': 'http://bad host:8000',
      'space in path': 'http://backend.example.test/a b',
      'newline': 'http://backend.example.test/a\nb',
      'null character': 'http://backend.example.test/a\u0000b',
      'delete character': 'http://backend.example.test/a\u007fb',
    };
    for (final entry in invalidUrls.entries) {
      test('rejects ${entry.key} without echoing the bad URL', () {
        expect(
          () => AppConfiguration.normalizeApiBaseUrl(
            entry.value,
            requireHttps: false,
          ),
          throwsA(
            _configurationError('API_BASE_URL').having(
              (AppConfigurationException error) => error.message,
              'sanitized diagnostic',
              isNot(contains(entry.value)),
            ),
          ),
        );
      });
    }
  });

  group('Phase A6 staging configuration (Railway)', () {
    const railwayHost = 'steadfast-curiosity-production-f250.up.railway.app';
    const stagingDefines = {
      'MAPKIT_API_KEY': _explicitKey,
      'API_BASE_URL': 'https://$railwayHost',
      'APP_ENV': 'staging',
    };

    test('staging resolves the Railway URL with exactly one api/v1 prefix', () {
      final configuration = AppConfiguration.resolve(
        defines: stagingDefines,
        isDebug: true,
      );
      expect(configuration.apiBaseUrl, 'https://$railwayHost/api/v1');
      expect(configuration.apiBaseUrl, isNot(contains('/api/v1/api/v1')));
      expect(configuration.appEnv, 'staging');
      expect(configuration.mapKitApiKey, _explicitKey);
    });

    test('a staging URL already carrying the prefix is not duplicated', () {
      final configuration = AppConfiguration.resolve(
        defines: {
          ...stagingDefines,
          'API_BASE_URL': 'https://$railwayHost/api/v1/',
        },
        isDebug: true,
      );
      expect(configuration.apiBaseUrl, 'https://$railwayHost/api/v1');
      expect('/api/v1'.allMatches(configuration.apiBaseUrl).length, 1);
    });

    test(
      'a local development file never overrides explicit staging values',
      () {
        final configuration = AppConfiguration.resolve(
          defines: stagingDefines,
          localValues: _localSettings,
          isDebug: true,
        );
        expect(configuration.apiBaseUrl, 'https://$railwayHost/api/v1');
        expect(configuration.apiBaseUrl, isNot(contains('10.0.2.2')));
        expect(configuration.apiBaseUrl, isNot(contains('192.168.1.100')));
      },
    );

    test('debug development still defaults to the emulator backend', () {
      final fallback = AppConfiguration.resolve(
        defines: const {'MAPKIT_API_KEY': _explicitKey},
        isDebug: true,
      );
      // The debug default is the local emulator backend, never a cloud host.
      // (load() supplies ApiConstants.defaultBaseUrl, which is the same host
      // on Android; resolve() documents the Android value as its default.)
      expect(fallback.apiBaseUrl, 'http://10.0.2.2:8000/api/v1');
      expect(fallback.apiBaseUrl, isNot(contains('railway')));
      expect(fallback.appEnv, 'development');
    });

    test('an explicitly empty staging URL fails instead of defaulting', () {
      expect(
        () => AppConfiguration.resolve(
          defines: {...stagingDefines, 'API_BASE_URL': ''},
          isDebug: true,
        ),
        throwsA(_configurationError('API_BASE_URL')),
      );
    });

    test('staging over plain HTTP is rejected outside debug', () {
      expect(
        () => AppConfiguration.resolve(
          defines: {...stagingDefines, 'API_BASE_URL': 'http://$railwayHost'},
          isDebug: false,
        ),
        throwsA(_configurationError('HTTPS')),
      );
    });
  });

  group('profile and release configuration', () {
    test('local configuration is ignored even when explicitly supplied', () {
      expect(
        () => AppConfiguration.resolve(
          defines: const {},
          localValues: _localSettings,
          isDebug: false,
        ),
        throwsA(
          isA<AppConfigurationException>().having(
            (error) => error.message,
            'missing explicit settings',
            allOf(
              contains('MAPKIT_API_KEY'),
              contains('API_BASE_URL'),
              contains('APP_ENV'),
              contains('--dart-define'),
            ),
          ),
        ),
      );
    });

    for (final missing in _releaseSettings.keys) {
      test('$missing must be selected explicitly in nondebug builds', () {
        final defines = Map<String, String>.of(_releaseSettings)
          ..remove(missing);
        expect(
          () => AppConfiguration.resolve(
            defines: defines,
            localValues: _releaseSettings,
            isDebug: false,
          ),
          throwsA(_configurationError(missing)),
        );
      });
    }

    test(
      'development environment and HTTP are invalid for nondebug builds',
      () {
        expect(
          () => AppConfiguration.resolve(
            defines: {..._releaseSettings, 'APP_ENV': 'development'},
            isDebug: false,
          ),
          throwsA(_configurationError('APP_ENV')),
        );
        expect(
          () => AppConfiguration.resolve(
            defines: {
              ..._releaseSettings,
              'API_BASE_URL': 'http://192.168.1.100:8000',
            },
            isDebug: false,
          ),
          throwsA(_configurationError('HTTPS')),
        );
      },
    );

    for (final environment in ['staging', 'production']) {
      test('explicit HTTPS $environment configuration is accepted', () {
        final configuration = AppConfiguration.resolve(
          defines: {..._releaseSettings, 'APP_ENV': environment},
          localValues: _localSettings,
          isDebug: false,
        );
        expect(configuration.appEnv, environment);
        expect(configuration.apiBaseUrl, 'https://backend.example.test/api/v1');
        expect(configuration.mapKitApiKey, _explicitKey);
      });
    }
  });

  group('configuration loading', () {
    test('debug waits for local settings before resolving overrides', () async {
      var reads = 0;
      final configuration = await AppConfiguration.load(
        defines: const {'MAPKIT_API_KEY': _explicitKey},
        isDebug: true,
        readDevelopmentValues: () async {
          reads++;
          return _localSettings;
        },
      );
      expect(reads, 1);
      expect(configuration.mapKitApiKey, _explicitKey);
      expect(configuration.apiBaseUrl, 'http://192.168.1.100:8000/api/v1');
    });

    test('loader preserves the existing platform default backend', () async {
      final configuration = await AppConfiguration.load(
        defines: const {'MAPKIT_API_KEY': _explicitKey},
        isDebug: true,
        readDevelopmentValues: () async => {},
      );
      expect(configuration.apiBaseUrl, ApiConstants.defaultBaseUrl);
      expect(configuration.appEnv, 'development');
    });

    test('nondebug never invokes the development loader', () async {
      var reads = 0;
      final configuration = await AppConfiguration.load(
        defines: _releaseSettings,
        isDebug: false,
        readDevelopmentValues: () async {
          reads++;
          throw StateError('Development credentials must not be read.');
        },
      );
      expect(reads, 0);
      expect(configuration.mapKitApiKey, _explicitKey);

      await expectLater(
        AppConfiguration.load(
          defines: const {},
          isDebug: false,
          readDevelopmentValues: () async {
            reads++;
            return _localSettings;
          },
        ),
        throwsA(_configurationError('--dart-define')),
      );
      expect(reads, 0);
    });

    test(
      'read errors produce safe instructions without raw secret data',
      () async {
        const secret = 'synthetic-key-in-parser-error';
        await expectLater(
          AppConfiguration.load(
            defines: const {},
            isDebug: true,
            readDevelopmentValues: () async {
              throw const FormatException('MAPKIT_API_KEY=$secret');
            },
          ),
          throwsA(
            isA<AppConfigurationException>().having(
              (error) => error.toString(),
              'safe local configuration instructions',
              allOf(contains('.env.dev'), isNot(contains(secret))),
            ),
          ),
        );
      },
    );
  });

  group('real dotenv asset loader', () {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

    setUp(() {
      rootBundle.evict('development.env');
    });

    tearDown(() {
      messenger.setMockMessageHandler('flutter/assets', null);
      rootBundle.evict('development.env');
    });

    test(
      'loads UTF8 generated development asset comments, quotes and backend',
      () async {
        final requests = <String>[];
        messenger.setMockMessageHandler('flutter/assets', (message) async {
          final requested = utf8.decode(
            message!.buffer.asUint8List(
              message.offsetInBytes,
              message.lengthInBytes,
            ),
          );
          requests.add(requested);
          if (requested != 'development.env') return null;
          const contents = '''
# Настройки локальной разработки
MAPKIT_API_KEY="synthetic-local-mapkit-key" # client credential
API_BASE_URL='http://192.168.1.100:8000/'
APP_ENV=development # select development
''';
          final bytes = Uint8List.fromList(utf8.encode(contents));
          return ByteData.sublistView(bytes);
        });

        final configuration = await AppConfiguration.load(
          defines: const {},
          isDebug: true,
        );
        expect(requests, contains('development.env'));
        expect(configuration.mapKitApiKey, _localKey);
        expect(configuration.apiBaseUrl, 'http://192.168.1.100:8000/api/v1');
        expect(configuration.appEnv, 'development');
      },
    );

    test(
      'an absent optional asset still supports complete explicit defines',
      () async {
        messenger.setMockMessageHandler('flutter/assets', (_) async => null);
        final configuration = await AppConfiguration.load(
          defines: _releaseSettings,
          isDebug: true,
        );
        expect(configuration.mapKitApiKey, _explicitKey);
        expect(configuration.apiBaseUrl, 'https://backend.example.test/api/v1');
        expect(configuration.appEnv, 'production');
      },
    );

    test(
      'an absent asset and absent key surface the required setting',
      () async {
        messenger.setMockMessageHandler('flutter/assets', (_) async => null);
        await expectLater(
          AppConfiguration.load(defines: const {}, isDebug: true),
          throwsA(_configurationError('MAPKIT_API_KEY')),
        );
      },
    );
  });
}
