# Сдача практической работы №2

Автор: [aaackermannn](https://gitverse.ru/aaackermannn). Работа выполнена индивидуально.

- [Форк](https://gitverse.ru/aaackermannn/course-multiplayer).
- Ветка: `feature/latency-measurement`.
- [Отчёт](Latency_Report.md), [конфигурация](Experiment_Config.md), [CSV](latency_samples.csv).
- Проверки: Debug, Release, отдельная чистая сборка; CTest — 3/3.
- Эксперимент: Clumsy 0.3, 6 серий по 100 PING; 584 received, 16 timeout.
- [PR №1](https://gitverse.ru/aaackermannn/course-multiplayer/pulls/1): `feature/latency-measurement` → `master`.

## Задачи

1. [Контракт PING/PONG](https://gitverse.ru/aaackermannn/course-multiplayer/tasktracker/TSKCRSMLTPL12-1).
2. [Телеметрия и состояния](https://gitverse.ru/aaackermannn/course-multiplayer/tasktracker/TSKCRSMLTPL12-2).
3. [UDP transport и приложения](https://gitverse.ru/aaackermannn/course-multiplayer/tasktracker/TSKCRSMLTPL12-3).
4. [Автоматические тесты](https://gitverse.ru/aaackermannn/course-multiplayer/tasktracker/TSKCRSMLTPL12-4).
5. [Эксперимент и CSV](https://gitverse.ru/aaackermannn/course-multiplayer/tasktracker/TSKCRSMLTPL12-5).
6. [Графики, отчёт и PR](https://gitverse.ru/aaackermannn/course-multiplayer/tasktracker/TSKCRSMLTPL12-6).

## Ревью при индивидуальной работе

[Саморевью в PR](https://gitverse.ru/aaackermannn/course-multiplayer/pulls/1#comment-1044988) и [таблица замечаний](Code_Review.md). Исправлены R1–R3: обязательный Python для тестов, отклонение обратных серверных меток времени и сохранность CSV при повторном run_id.

- Проверены порядок байтов, размеры и границы буферов.
- Проверены RTT/SRTT/jitter/loss и переходы timeout → late → duplicate.
- Проверены лимиты истории и независимое расписание PING.
- Метрики заново рассчитаны из CSV и совпали с итогами клиента.
- Выполнена сборка и запуск тестов из отдельной копии репозитория.

Ревью другого участника не проводилось: работа индивидуальная. GitVerse не позволяет автору одобрить собственный PR. Саморевью опубликовано как комментарий ревью. Принятие индивидуального формата вместо ревью участника команды определяет преподаватель.

Основные CSV и графики обновлены по завершённому эксперименту Clumsy 0.3 (6×100). В jitter/combined переменная задержка остаётся в сервере и явно описана. Первый серверный опыт сохранён отдельным архивом. Команды, SHA256 и логи включены в репозиторий.
