# Сторонние компоненты

| Компонент | Как используется | Лицензия |
|---|---|---|
| [ungive/mediaremote-adapter](https://github.com/ungive/mediaremote-adapter) | git-подмодуль в `Vendor/`, «Сейчас играет» и управление плеером | BSD 3-Clause, см. `Vendor/mediaremote-adapter/LICENSE` |
| [MacPaw/OpenAI](https://github.com/MacPaw/OpenAI) | Swift-пакет, клиент OpenAI API | MIT |
| [apple/swift-openapi-runtime](https://github.com/apple/swift-openapi-runtime), [apple/swift-http-types](https://github.com/apple/swift-http-types) | зависимости MacPaw/OpenAI | Apache 2.0 |
| [cyberjunky/python-garminconnect](https://github.com/cyberjunky/python-garminconnect) | ставится в отдельный venv при подключении Garmin, вызывается из `Resources/garmin_sync.py` | MIT |

Приложение использует закрытый системный фреймворк MediaRemote (через mediaremote-adapter). Apple может изменить его в любом обновлении macOS.
