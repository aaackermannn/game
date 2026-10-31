# Практическая работа №2: телеметрия UDP

Реализован учебный шаблон [univ-mirea-iit/course-multiplayer](https://gitverse.ru/univ-mirea-iit/course-multiplayer/content/master/pr2-latency-template), исходный commit `b01e0606978451047580a2938c998e6a0fb58b9c`. C++17, отдельный dedicated-сервер, PING/PONG с явной сериализацией, проверкой датаграмм, RTT/SRTT/jitter/loss и ограниченным реестром измерений. Повторных передач нет.

Результаты шести серий от 31 октября 2026 года: 300 PING, 294 успешных ответа, 6 тайм-аутов. Эксперимент выполнен через loopback со встроенной очередью отложенных PONG.

## Сборка и проверки

Зависимости: CMake >=3.16, компилятор C++17 (MSVC/GCC/Clang), Python 3 для интеграционных тестов и анализа CSV. При первой конфигурации нужен интернет для Catch2 v3.5.2. Для графиков отдельно установить `scripts/requirements.txt`.

Из этого каталога:

```powershell
cmake -S . -B build
cmake --build build --config Release --parallel 4
ctest --test-dir build -C Release --output-on-failure
python -m pip install -r scripts/requirements.txt
```

В Linux/macOS исполняемые файлы лежат непосредственно в build; можно добавить `-DCMAKE_BUILD_TYPE=Release`. Проверка POSIX в этой сессии локально не выполнялась.

При работе из корня Loop использована отдельная сборка:

```powershell
cmake -S pr2-latency-template -B build/pr2
cmake --build build/pr2 --config Release --parallel 4
ctest --test-dir build/pr2 -C Release --output-on-failure
```

Для офлайн-сборки локальный Catch2 можно передать через `-DFETCHCONTENT_SOURCE_DIR_CATCH2=<путь>`. Python обязателен для сборки с тестами; путь задаётся через `-DPython3_EXECUTABLE=<путь к python>`. Явная сборка без тестов: `-DBUILD_TESTING=OFF`.

## Ручной запуск

В первом терминале:

```powershell
.\build\Release\server.exe --bind 127.0.0.1 --port 27015 --profile baseline --seed 20261031
```

Во втором:

```powershell
.\build\Release\client.exe --host 127.0.0.1 --port 27015 --experiment baseline --count 50 --interval-ms 500 --timeout-ms 1000 --grace-ms 1200 --csv docs/manual_samples.csv --run-id manual_baseline_1
```

Сервер завершается по Ctrl+C либо `--duration-ms`. Для подключения с других машин явно указать подходящий `--bind` и доступный адрес клиента `--host`; в эксперименте сервер слушал только loopback. Клиент заканчивает серию самостоятельно. Ошибки CLI/файла/отправки возвращают ненулевой код. Успешный сбор результатов, включая 100% тайм-аутов, возвращает 0 и печатает JSON после префикса `SUMMARY `.

CLI принимает только пары `--параметр значение`; все опции показаны через `--help`. Ограничения: port 1..65535, count 1..60000, interval-ms 200..1000, timeout-ms 1..60000, grace-ms 0..60000. Идентификаторы состоят из 1..80 ASCII-букв, цифр, `_` и `-`. Для отчётного эксперимента count >=50. Приём не блокирует расписание отправок. Существующий CSV дополняется; повторный run-id и несовместимый заголовок отклоняются.

## Повторить эксперимент и графики

Существующие исходные данные не перезаписываются. Для нового запуска выбрать новый каталог:

```powershell
python scripts/run_experiments.py --bin-dir build/Release --output-dir docs/repeat_1
python scripts/analyze_latency.py --docs docs/repeat_1
```

Для сохранённого эксперимента достаточно:

```powershell
python scripts/analyze_latency.py --docs docs
```

Запуск с официальным Clumsy 0.3 выполняется из терминала администратора:

```powershell
python scripts/run_experiments.py --bin-dir build/Release --output-dir docs/clumsy_run --count 100 --interval-ms 200 --clumsy C:/tools/clumsy/clumsy.exe
python scripts/analyze_latency.py --docs docs/clumsy_run
```

Clumsy фильтрует только исходящие UDP-пакеты localhost с портом отправителя 27015. Задержки 50/100 мс и потери задаются Clumsy; переменный компонент jitter остаётся в сервере и записывается в manifest. Перед сериями с задержкой выполняется отдельный калибровочный PING. Seed сервера фиксирован; seed Clumsy недоступен.

Этот дополнительный режим пока не проверен запуском Clumsy. Опубликованные измерения выполнены встроенным серверным эмулятором; согласование его использования отмечено в конфигурации эксперимента.

PowerShell-обёртка из корня Loop: `./pr2-latency-template/scripts/run_experiments.ps1 -BinDir ./build/pr2/Release -OutputDir ./pr2-latency-template/docs/repeat_1`. Параметр `-Python` позволяет выбрать интерпретатор.

При ограничении записи в домашний каталог для matplotlib задайте `MPLCONFIGDIR` на доступный каталог кэша. Числа и графики заново выводятся из CSV и сверяются с сохранёнными итогами клиента. Между маркерами metrics в отчёте таблица обновляется автоматически; текст интерпретации для нового эксперимента следует пересмотреть.

## Архитектура и материалы

- `include/protocol`, `src/protocol.cpp`: формат и валидация без сокетов/часов.
- `include/telemetry`, `src/telemetry.cpp`: состояния и статистика с передаваемым временем, без сети/файлов.
- `include/transport`, `src/transport`: UDP и RAII, без протокола/метрик.
- `src/client_main.cpp`, `src/server_main.cpp`, `include/app`: CLI, монотонные часы, CSV, серверная очередь/эмулятор.
- `tests`: Catch2, независимый анализ CSV и реальные UDP-сценарии с искусственно заданными ошибками.
- [Спецификация](docs/Protocol_Specification.md), [конфигурация](docs/Experiment_Config.md), [отчёт с графиками](docs/Latency_Report.md).
- [CSV](docs/latency_samples.csv), [manifest](docs/experiment_manifest.json), [метрики](docs/metrics.json), [логи](docs/experiment_logs/).
- [Оформление сдачи, issues, PR и ревью](docs/Submission_Checklist.md).
- [Саморевью кода](docs/Code_Review.md).

Формат ПР №2 несовместим с 12-байтовым форматом ПР №1 Loop. Приложения ПР №1 сохранены отдельно в родительском проекте. Здесь MOVEMENT/SHOOT распознаются и логируются по контракту нового заголовка; игровая симуляция не переносилась в подсистему измерений.
