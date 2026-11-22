# Матрица тестов — практическая работа №4

Все опыты: Godot 4.4.1, Windows 11, listen server и клиент на одной машине (127.0.0.1), окна 960×540, 60 тиков/с, снапшоты 30 Гц. Клиент едет автопилотом по кругу, нажатия рывка и читы — по сценарию (`docs/prediction_logs/T*_timeline_client.txt`), seed эмулятора 4242. Повторить: `python kart/tools/netlab/run_prediction_tests.py --godot <Godot.exe> --frames <папка>`. Сводка чисел — [`prediction_logs/summary.json`](prediction_logs/summary.json).

| Тест | Сетевые условия | Действие | Ожидаемый результат | Фактический результат | Артефакт |
|---|---|---|---|---|---|
| T1 | Без эмуляции (RTT ≈ 41 мс — только кадровая дискретизация) | Движение (+3 рывка) | Плавное перемещение и репликация | 0 коррекций за 12 с; 3/3 рывка приняты сервером; клиент и сервер показывают одно и то же; хост виден клиенту как simulated proxy | [T1_movement.png](media/T1_movement.png), [лог клиента](prediction_logs/T1_client.csv), [лог сервера](prediction_logs/T1_server.csv) |
| T2 | 100 мс, 0% loss (в каждую сторону; RTT ≈ 266 мс) | Рывок **без CSP** (reliable RPC) | Видимая задержка до подтверждения | Нажатие → реакция: **293.3 мс** в среднем (266.6 / 307.6 / 311.8 / 275.9 / 302.7 / 295.1); 6/6 приняты; на каждый рывок одна коррекция `dash_state` (до 3.66 м) — карт «прыгает» вперёд | [baseline_no_prediction.mp4](media/baseline_no_prediction.mp4), [.png](media/baseline_no_prediction.png), [лог](prediction_logs/T2_client.csv) |
| T3 | 100 мс, 0% loss (RTT ≈ 267 мс) | Рывок **с CSP** | Немедленный отклик, сервер сохраняет авторитетность | Нажатие → реакция: **0.2 мс** (тот же тик), n=6; сервер сам принял 6/6 (`server_dash_accept path=input`); **0 коррекций** — предсказание совпало | [prediction_enabled.mp4](media/prediction_enabled.mp4), [.png](media/prediction_enabled.png), [лог](prediction_logs/T3_client.csv) |
| T4 | 175±25 мс, 5% loss в каждую сторону (RTT ≈ 417 мс) | Движение и рывок: 6 с CSP, 1 попытка в кулдауне, 3 без CSP | Система не принимает недопустимое состояние; возможны коррекции | Потеряно 68/1279 исходящих (5.3%) и 38 входящих; позиционных коррекций **0** (избыточный ввод покрыл потери); CSP — 0.2 мс; попытку в кулдауне клиент заблокировал сам, сервер тоже отклонил (`why=cooldown`); без CSP — 481 / 428 / 1174 мс (последний RPC «потерян» и пришёл повторно), 3 коррекции `dash_state`; 9 приняты, 1 отклонён | [T4_bad_network.png](media/T4_bad_network.png), [лог клиента](prediction_logs/T4_client.csv), [лог сервера](prediction_logs/T4_server.csv) |
| T5 | 175±25 мс, 5% loss (RTT ≈ 434 мс) | Намеренное расхождение: `cheat.IgnoreCooldown`, `cheat.SpeedMult 1.6`, `cheat.DoubleTick` | Клиент получает авторитетную коррекцию | Сервер отклонил 2 рывка в кулдауне, клиент откатился на 3.3 м (`REJECTED: COOLDOWN`, `CORRECTED!`); SpeedMult — коррекции на каждом снапшоте; DoubleTick — сервер отклонил 91 ход по бюджету времени, откат до 3.9 м; всего 73 коррекции; связь не разорвана, после выключения читов коррекции прекратились | [correction_example.mp4](media/correction_example.mp4), [.png](media/correction_example.png), [correction_speedhack.png](media/correction_speedhack.png), [лог клиента](prediction_logs/T5_client.csv), [лог сервера](prediction_logs/T5_server.csv) |

## Как читать логи

CSV: `t_ms` (от старта процесса), `wall_ms` (общие часы для клиента и сервера), `role`, `event`, `details`.

| Событие | Значение |
|---|---|
| `dash_press` | игрок нажал рывок (`mode=CSP` или `RPC`) |
| `dash_reaction` | первый кадр, где свой карт начал рывок; `latency_ms` = нажатие → реакция |
| `client_dash_blocked_locally` | честный клиент сам знает, что сервер скажет «нет» (кулдаун) |
| `server_dash_accept` / `server_dash_reject` | решение сервера (`why=cooldown/already_dashing/too_slow`) |
| `client_correction` | снапшот не совпал с сохранённым ходом: `err`, `snap_m` (на сколько метров откатили), `why`, `replayed` (сколько ходов проиграно заново) |
| `server_reject_move` | сервер не стал симулировать ход сверх бюджета времени |
