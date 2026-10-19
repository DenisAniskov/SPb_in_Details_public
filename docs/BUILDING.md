# Сборка

## Требования

| Компонент | Версия |
| --- | --- |
| Flutter | 3.47.6 stable (минимум 3.47.0) |
| Dart | 3.13.5 (ограничение pubspec: `>=3.13.0 <4.0.0`) |
| JDK | 21 (`JAVA_HOME` должен указывать на него) |
| Android SDK | platform 36, build-tools из состава AGP 8.13.2 |
| Gradle | wrapper 8.14.3 (входит в репозиторий) |
| Python | 3.10+ — только для `tool/generate_branding_icons.py` |

Gradle wrapper, Kotlin-исходники и ресурсы Android входят в репозиторий.
`android/local.properties` с путём к SDK и Flutter создаётся локально и не
коммитится — его обычно пишет сам `flutter` при первой сборке.

## Установка и проверки

```bash
flutter pub get
flutter analyze
flutter test
```

## Debug APK

Debug-сборка компилируется без действующего ключа MapKit: ключ нужен для
запуска, а не для компиляции.

```bash
cp .env.example .env.dev      # впишите ключ и адрес backend
flutter build apk --debug
```

Debug-APK содержит локальные настройки из `.env.dev`, поэтому его не следует
распространять публично со своими ключами. Он подписан стандартным debug-ключом
Android и не является публикацией.

## Release: конфигурация и подпись

Release-сборка требует **и** явной клиентской конфигурации
(`--dart-define`/`--dart-define-from-file`, см.
[CONFIGURATION.md](CONFIGURATION.md)), **и** постоянного release-keystore.
Без любого из двух условий сборка останавливается:

- Gradle-задача `validateExplicitClientEnvironment` проверяет настройки клиента;
- Gradle-задача `validateReleaseSigning` проверяет наличие
  `android/key.properties` и реальных значений в нём.

### Постоянный ключ подписи

Release-подпись — долговременный ключ приложения. Его потеря затрудняет выпуск
совместимых обновлений, поэтому ключ создаётся и хранится вне Git, отдельно от
проекта, с резервной копией.

```bash
# выполняет владелец релиза, один раз; файл и пароли хранятся вне репозитория
keytool -genkeypair -v -keystore release-upload.jks \
  -keyalg RSA -keysize 4096 -validity 10000 -alias upload
```

```bash
cp android/key.properties.example android/key.properties
```

```properties
storeFile=../keys/release-upload.jks
storePassword=...
keyAlias=upload
keyPassword=...
```

`storeFile` может быть относительным (тогда путь считается от каталога
`android/`) или абсолютным; используйте прямые слэши. `android/key.properties`,
`*.jks`, `*.keystore`, `*.p12` и `*.key` исключены из Git через `.gitignore`.

**Хранение и резервная копия.** Keystore и пароли храните в менеджере секретов
владельца релиза и держите минимум одну проверенную резервную копию вне
рабочей машины. Пароли не передаются в чатах, не попадают в логи CI и не печатаются в
отчётах сборки.

### Сборка release

```bash
flutter build apk --release --dart-define-from-file=.env.production.json
flutter build appbundle --release --dart-define-from-file=.env.production.json
```

### Совместимость обновлений

APK, подписанная новым release-ключом, **не устанавливается обновлением поверх
ранее выпущенной debug-APK** (или любой сборки с другим сертификатом): Android
требует совпадения подписи. Пользователю придётся удалить прежнюю сборку, а
локальные данные приложения при этом будут потеряны. Бесшовное обновление
между разными сертификатами не обещается.

## Непрерывная интеграция

`.github/workflows/ci.yml` выполняет на каждый push в `main` и каждый pull request:

| Задача | Содержание |
| --- | --- |
| `verify` | `flutter analyze`, полный `flutter test`, проверки снимка (`tool/check_release_snapshot.py`) и отчёт о форматировании изменённых файлов |
| `android` | debug-сборка без credentials, проверка метаданных APK и негативный тест: release-сборка обязана отказаться работать без keystore |

Особенности окружения, зафиксированные в workflow:

- **Часовой пояс `Europe/Moscow`.** Тесты сервисов закрепляют ISO-8601 с
  локальным смещением (МСК), поэтому на UTC-раннере часть проверок падала бы
  по причине окружения, а не кода. Workflow выставляет `TZ` явно.
- **Шрифты Material.** Ширинные проверки шапки загружают реальные файлы
  Roboto из кэша Flutter, поэтому задача `verify` выполняет
  `flutter precache --universal`. Без доступных файлов эти проверки
  пропускаются, а не падают: тест требует наличия файлов, а не только каталога.
- **Форматирование — рекомендательное.** Существующий код написан до
  форматтера Dart 3.13 (tall style): массовый переформат 70+ файлов, включая
  сгенерированный scenic-набор, не входит в задачи релизного снимка, поэтому
  отчёт о расхождениях не валит сборку. Для новых файлов запускайте
  `dart format` локально.
- **Артефакты не публикуются.** CI не выгружает debug-APK: она не содержит
  локальных настроек, но всё равно не должна выглядеть публикацией.

Заявлять про успешность CI можно только по фактическому результату
запущенного workflow.

## Проверка артефакта

```bash
# подпись и сертификат
apksigner verify --verbose --print-certs build/app/outputs/flutter-apk/app-release.apk

# выравнивание
zipalign -c -p 4 build/app/outputs/flutter-apk/app-release.apk

# метаданные пакета: имя, версия, минимальная и целевая версия Android, иконки
aapt2 dump badging build/app/outputs/flutter-apk/app-release.apk

# контрольная сумма
sha256sum build/app/outputs/flutter-apk/app-release.apk
```

Ожидаемые значения метаданных: `applicationId` `ru.smartnavigator.spb`, метка
`Петербург в деталях`, `minSdk 26`, `targetSdk 36`, версия из `pubspec.yaml`
(`1.0.0+1`).

## Операционные замечания

- **Чистая сборка.** Инкрементальная упаковка Gradle в некоторых окружениях
  переиспользует предыдущий файл APK, оставляя в ZIP мёртвые области
  заполнения. Перед эталонной сборкой выполняйте `flutter clean`.
- **`JAVA_HOME`.** Если Gradle сообщает, что JDK не найден, задайте переменную
  на JDK 21 до запуска сборки.
- **Кэш Kotlin.** `kotlin.incremental=false` в `android/gradle.properties`
  отключён намеренно: инкрементальный кэш Kotlin не умеет корректно
  относить пути, когда pub-cache и проект лежат на разных дисках Windows.
- **Тулчейн.** Версии Flutter, Dart, JDK и Android SDK зафиксированы в
  `pubspec.lock`, wrapper и этом документе; менять их стоит согласованно, чтобы
  результат сборки оставался воспроизводимым.

## Регенерация ресурсов иконки

```bash
python tool/generate_branding_icons.py
```

Скрипт детерминированно пересобирает слои адаптивной иконки, legacy-иконки и
монохромный слой из утверждённого источника
`docs/branding/original_app_icon.png` (размер и SHA-256 зафиксированы в
`docs/branding/icon_metadata.json`). Оригинал не изменяется. Подробности:
[BRANDING.md](BRANDING.md).
