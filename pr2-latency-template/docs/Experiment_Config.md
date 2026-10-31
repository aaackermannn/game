# Конфигурация эксперимента

Работа выполнена индивидуально. Основной эксперимент: **2026-10-31T23:42:57+03:00 — 2026-10-31T23:45:15+03:00**, Europe/Moscow (UTC+03:00). [CSV](latency_samples.csv), [manifest с командами и SHA256](experiment_manifest.json), [логи](experiment_logs/).

| Параметр | Значение |
|---|---|
| ОС | Windows 11, build 26200, AMD64 |
| Компилятор | MSVC 19.51.36256, Visual Studio 18 2026 Community, x64 |
| SDK / CMake | 10.0.26100.0 / 4.4.3 |
| Сборка | Release, C++17 |
| Проверки | Catch2 v3.5.2, Python unittest, CTest; Debug и Release |
| Анализ | Python 3.12.14, matplotlib 3.10.7, Agg, PNG 180 dpi |
| Стенд | Два процесса на одном ПК, 127.0.0.1:27015/UDP |
| Размеры | PING 15 байт, PONG 31 байт |
| Выборка | 6 серий × 100 PING = 600 |
| Интервал | 200 мс; отправка не ждёт предыдущего ответа |
| Тайм-аут / grace | 1000 / 1200 мс; <=1000 принято, >1000 просрочено |
| История / attempts | До 1024 записей; pending не вытесняется; attempts=1 |
| Эмулятор | Официальный Clumsy 0.3 win64; WinDivert |
| Направление | Только исходящие loopback UDP с портом отправителя 27015 |
| Seed | Сервер: 20261031; Clumsy сам задаёт seed, извне он не фиксируется |

Фильтр Clumsy:

```text
outbound and udp and ip.SrcAddr == 127.0.0.1 and ip.DstAddr == 127.0.0.1 and udp.SrcPort == 27015
```

| Серия | Clumsy | Сервер |
|---|---|---|
| baseline | Не запущен | baseline |
| delay_50 | Lag 50 мс, outbound | baseline |
| delay_100 | Lag 100 мс, outbound | baseline |
| jitter | Фильтр включён, Lag/Drop выключены | Равномерная целая задержка 50..150 мс |
| loss_5 | Drop 5%, outbound | baseline |
| combined | Drop 5%, outbound | 100 мс + целое отклонение −50..+50 мс |

**Переменная задержка в jitter и combined встроена в сервер.** Она реализована очередью дедлайнов без sleep на каждый PING. Clumsy в остальных профилях задаёт постоянную задержку и/или реальные пропуски исходящих PONG. Это смешанный стенд; переменную задержку нельзя приписывать Clumsy. Его стандартный Lag задаёт фиксированное время: [исходный код](https://github.com/jagt/clumsy/blob/master/src/lag.c), [руководство](https://jagt.github.io/clumsy/manual.html).

Сервер использует xorshift32, два вызова на валидный PING: loss_draw, jitter_draw. Задержка равна 50+jitter_draw%101 мс. В Clumsy-режиме встроенные пропуски выключены. Одинаковый seed делает последовательность jitter одинаковой в jitter и combined; серии не являются независимыми случайными повторениями. Modulo bias и колебания планировщика сохраняются. Потери Clumsy случайны и не повторяются побитно при новом запуске.

Перед delay_50 и delay_100 отправлен отдельный калибровочный PING с sequence=65535. Он не входит в CSV и 100 отсчётов серии. Фактические калибровочные RTT: 93.000 и 110.000 мс. Они подтверждают действие фильтра, а не точность заданного Lag до микросекунды.

Clumsy скачан из [официального релиза 0.3](https://github.com/jagt/clumsy/releases/tag/0.3). SHA256 exe: `088d012a3d2788f797faf54d4f3db945c84ddab03a656c24d3badb06ae74324e`. Подпись WinDivert64.sys проверена Windows; запуск с правами администратора разрешён владельцем компьютера. Runner завершает только свои дочерние процессы после каждой серии. Фильтр не охватывает интернет-трафик.

## Повторение

Из каталога pr2-latency-template:

```powershell
cmake -S . -B build
cmake --build build --config Release --parallel 4
ctest --test-dir build -C Release --output-on-failure
python -m pip install -r scripts/requirements.txt
# Следующая команда выполняется из терминала администратора:
python scripts/run_experiments.py --bin-dir build/Release --output-dir docs/repeat_clumsy --clumsy C:/tools/clumsy/clumsy.exe --count 100 --interval-ms 200 --timeout-ms 1000 --grace-ms 1200 --seed 20261031 --port 27015
python scripts/analyze_latency.py --docs docs/repeat_clumsy
```

Точные фактические пути и команды сохранены в manifest. В этой среде Python взят из bundled runtime, Catch2 — из локального кэша через FETCHCONTENT_SOURCE_DIR_CATCH2. При обычной установке CMake получает Catch2 автоматически. Для matplotlib при необходимости задаётся доступный MPLCONFIGDIR.

Runner проверяет свободный порт, ожидает READY, выполняет серии последовательно, сохраняет run_id, команды, время, SHA256 исходников и exe, summary и логи. Частичный опыт имеет completed=false и не принимается анализатором. Для повторения нужен новый output-dir. Метрики проверяются независимо по CSV.

Первый опыт со встроенным эмулятором (6×50, интервал 500 мс) сохранён в [архиве](server_emulator_20261031.zip). Он не смешан с основным CSV. SHA256 исходников в каждом manifest относятся к моменту измерения; после опыта менялись только отчётные материалы.
