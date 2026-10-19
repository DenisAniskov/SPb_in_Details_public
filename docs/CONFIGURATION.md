# Конфигурация клиента

Приложение читает три настройки: `MAPKIT_API_KEY`, `API_BASE_URL`, `APP_ENV`.
Они загружаются и проверяются до инициализации MapKit и до создания сетевых
репозиториев. Значения ключей никогда не выводятся в сообщениях об ошибках и
логах.

## Переменные

| Переменная | Обязательна | Значение |
| --- | --- | --- |
| `MAPKIT_API_KEY` | да (для запуска) | Мобильный клиентский ключ Yandex MapKit. Значения-заглушки отклоняются. |
| `API_BASE_URL` | да | Адрес backend. Для release/profile — только абсолютный HTTPS URL без логина, query и fragment. |
| `APP_ENV` | да | `development`, `staging` или `production`. Для release/profile допустимы только `staging` и `production`. |

`API_BASE_URL` принимает корень сервера (`https://api.example.com`) или URL
уже с `/api/v1`. Клиент добавляет `/api/v1` к корню, убирает завершающий
slash, а существующий суффикс `/api/v1` сохраняет. Отдельный endpoint вроде
`/places` указывать нельзя.

## Приоритет

Приоритет определяется отдельно для каждой настройки:

1. Явный `--dart-define` или значение из выбранного `--dart-define-from-file`.
2. `.env.dev` в корне репозитория — **только для Android debug**.
3. Debug-значения по умолчанию: `APP_ENV=development` и локальный адрес API
   (`http://10.0.2.2:8000` на Android). Для ключа MapKit значения по умолчанию
   нет.

Явно пустое значение (`--dart-define=MAPKIT_API_KEY=`) тоже имеет приоритет и
приводит к ошибке конфигурации: приложение не подставляет вместо него ключ из
`.env.dev`. Другие варианты файлов (`.env.local`, `.env.production`) не
загружаются автоматически, а переменные окружения PowerShell/ОС сами по себе
не становятся настройками приложения.

## Debug: локальный `.env.dev`

```bash
cp .env.example .env.dev
```

```ini
MAPKIT_API_KEY=YOUR_MAPKIT_KEY
API_BASE_URL=http://192.168.1.100:8000
APP_ENV=development
```

`.env.dev` лежит в корне репозитория рядом с `pubspec.yaml` и не коммитится.
Gradle копирует его в debug-сборку как asset `flutter_assets/development.env`;
release/profile этот asset не включают, потому что файл не объявлен в
`pubspec.yaml`. После правки `.env.dev` нужен полный перезапуск: hot reload и
hot restart не пересобирают Android asset.

Адрес backend для разных устройств:

| Среда | `API_BASE_URL` в `.env.dev` | Условие |
| --- | --- | --- |
| Android Emulator | `http://10.0.2.2:8000` | FastAPI запущен на компьютере-хосте эмулятора |
| Физический смартфон | `http://192.168.1.100:8000` (реальный IPv4 компьютера) | Устройство и компьютер в одной доступной сети, firewall разрешает TCP 8000 |
| Устройство с `adb reverse` | `http://127.0.0.1:8000` | Порт перенаправлен для конкретного подключённого устройства |
| Удалённый сервер | `https://...` с действительным сертификатом | Сервер доступен по HTTPS |

```bash
adb devices
adb -s DEVICE_ID reverse tcp:8000 tcp:8000
```

Открытый HTTP разрешён только в debug: основной манифест объявляет
`android:usesCleartextTraffic="false"`, а debug-manifest переопределяет его.

## Release и profile: только явные define

Release и profile требуют все три настройки явно, без `.env.dev` и без
debug-значений по умолчанию. Gradle проверяет их до компиляции Dart и
останавливает сборку:

- `MAPKIT_API_KEY`: непустой, без пробелов, управляющих символов и заглушек
  вида `YOUR_`, `REPLACE_`, `CHANGEME`, `PLACEHOLDER`, `TODO`;
- `API_BASE_URL`: абсолютный HTTPS URL без учётных данных, query и fragment;
- `APP_ENV`: только `staging` или `production`.

```bash
# локальный файл с настройками, который не коммитится
cat > .env.production.json <<'JSON'
{
  "MAPKIT_API_KEY": "YOUR_MAPKIT_KEY",
  "API_BASE_URL": "https://api.example.com",
  "APP_ENV": "production"
}
JSON

flutter build apk --release --dart-define-from-file=.env.production.json
```

Отдельные `--dart-define` имеют приоритет над одноимёнными значениями файла.
Не публикуйте команды с реальным ключом: он попадёт в историю команд и логи.

## Ключи backend

`GEOCODER_API_KEY`, `SUGGEST_API_KEY` и ключ OpenRouter остаются на сервере.
Они не передаются во Flutter, не входят в `.env.dev` и не попадают в APK.
Статический токен внутри APK не является защищённой серверной
аутентификацией.

## Проверка и типичные ошибки

| Сообщение | Причина |
| --- | --- |
| `MAPKIT_API_KEY: ...` | Ключ отсутствует, пуст или является заглушкой |
| `API_BASE_URL: ...` | Относительный URL, HTTP вместо HTTPS или лишние параметры |
| `APP_ENV: ...` | Неизвестное окружение; для release допустимы `staging`/`production` |
| `Client configuration is invalid` | Gradle-проверка release/profile сборки |

Корректный по формату ключ не подтверждает его активацию, ограничения
приложения и квоты у Яндекса: это проверяется только на устройстве с реальным
ключом.

## Что нельзя коммитить

`.env.dev`, `.env.production.json`, `staging.local.json`, `android/key.properties`,
keystore и пароли подписи, а также любые реальные ключи. В репозиторий входят
только шаблоны: [`.env.example`](../.env.example),
[`staging.local.example.json`](../staging.local.example.json) и
[`android/key.properties.example`](../android/key.properties.example).
