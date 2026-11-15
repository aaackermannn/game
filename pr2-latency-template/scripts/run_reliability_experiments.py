"""Run the six PR3 UDP series, check delivery events and plot the measurements."""

import argparse
from collections import Counter, defaultdict
import csv
from datetime import datetime, timedelta, timezone
import math
import os
from pathlib import Path
import re
import socket
import statistics
import subprocess
import tempfile
import time


PROFILES = ("baseline", "loss_5", "loss_10", "loss_20", "delay_100_loss_5", "jitter_loss_10")
FIELDS = ("experiment_id", "run_id", "event", "sequence", "at_ms", "attempts", "rto_ms", "time_to_ack_ms")
CHARTS = ("reliability_attempts_by_loss.png", "reliability_rto_jitter.png")
FLAGS = subprocess.CREATE_NO_WINDOW if os.name == "nt" else 0
MOSCOW = timezone(timedelta(hours=3))
APPLIED_COMMAND = re.compile(r"^COMMAND type=4 seq=(\d+)\b", re.MULTILINE)
DUPLICATE_COMMAND = re.compile(r"^DUPLICATE seq=(\d+)\b", re.MULTILINE)
ACK_DECISION = re.compile(r"^ACK seq=\d+ peer=\S+ drop=([01])\b", re.MULTILINE)


def server_and_client(binaries):
    extension = ".exe" if os.name == "nt" else ""
    binaries = binaries.resolve()
    return binaries / ("server" + extension), binaries / ("client" + extension)


def run_series(server, client, directory, profile, args):
    server_log = directory / (profile + "_server.txt")
    run_id = datetime.now(MOSCOW).strftime("pr3_%Y%m%dT%H%M%S_%f_") + profile
    max_runtime_ms = args.count * args.interval_ms + args.max_attempts * 3000 + 5000
    server_cmd = [str(server), "--bind", "127.0.0.1", "--port", str(args.port),
                  "--profile", profile, "--seed", str(args.seed), "--duration-ms", str(max_runtime_ms + 5000)]
    client_cmd = [str(client), "--port", str(args.port), "--mode", "reliability", "--experiment", profile,
                  "--run-id", run_id, "--count", str(args.count), "--interval-ms", str(args.interval_ms),
                  "--ping-interval-ms", str(args.ping_interval_ms), "--max-attempts", str(args.max_attempts),
                  "--csv", "reliability_samples.csv"]
    print("START", profile, flush=True)
    with server_log.open("wb") as log, subprocess.Popen(
        server_cmd, cwd=directory, stdout=log, stderr=subprocess.STDOUT, creationflags=FLAGS
    ) as process:
        try:
            # Сигнал READY приходит после bind. До него запуск клиента исказил бы первую пробу.
            deadline = time.monotonic() + 5
            while not server_log.read_bytes().startswith(b"READY "):
                if process.poll() is not None or time.monotonic() >= deadline:
                    raise RuntimeError(f"{profile}: server startup failed\n{server_log.read_bytes()!r}")
                time.sleep(0.01)
            completed = subprocess.run(
                client_cmd, cwd=directory, capture_output=True, text=True, encoding="utf-8",
                errors="replace", timeout=max_runtime_ms / 1000, creationflags=FLAGS,
            )
            if completed.returncode:
                raise RuntimeError(f"{profile}: client failed\n{completed.stdout}{completed.stderr}")
            # ACK без задержки может дойти до клиента раньше записи о выполнении команды на сервере.
            time.sleep(0.05)
        finally:
            # Закрываем только процесс этой серии. Каждая следующая серия начинает с чистого состояния.
            if process.poll() is None:
                process.terminate()
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait(timeout=5)
    evidence = server_log.read_text(encoding="utf-8", errors="replace")
    if not APPLIED_COMMAND.search(evidence):
        raise RuntimeError(f"{profile}: no SHOOT reached the loopback server\n{evidence}")
    return run_id, evidence


def metric_value(raw):
    value = float(raw)
    if not math.isfinite(value) or value < 0:
        raise ValueError(f"invalid measurement {raw!r}")
    return value


def read_series(path):
    groups = defaultdict(list)
    with path.open(newline="", encoding="utf-8") as stream:
        reader = csv.DictReader(stream, delimiter=";")
        if tuple(reader.fieldnames or ()) != FIELDS:
            raise ValueError("unexpected event CSV header")
        for row in reader:
            if None in row or None in row.values():
                raise ValueError("inconsistent event CSV columns")
            groups[(row["experiment_id"], row["run_id"])].append(row)
    return groups


def analyze_series(profile, rows, count, max_attempts, server_log):
    attempts = {}
    first_sent = {}
    outcomes = {}
    ack_times = []
    timeline = []
    terminal_rtos = []
    retransmit_count = 0
    for index, row in enumerate(rows):
        at_ms = metric_value(row["at_ms"])
        rto_ms = metric_value(row["rto_ms"])
        if not 100 <= rto_ms <= 3000 or (timeline and at_ms < timeline[-1][0]):
            raise ValueError(f"{profile}: invalid RTO or event chronology")
        timeline.append((at_ms, rto_ms))
        event = row["event"]
        if event == "final" and index != len(rows) - 1:
            raise ValueError(f"{profile}: premature final event")
        if event in ("pong_sample", "final"):
            continue
        seq = int(row["sequence"])
        attempt = int(row["attempts"])
        if not 0 <= seq <= 65535 or seq in outcomes:
            raise ValueError(f"{profile}: invalid or already completed sequence {seq}")
        if event in ("sent", "retransmit"):
            # Номер попытки в журнале обязан совпасть с числом отправок этого sequence.
            expected = attempts.get(seq, 0) + 1
            if attempt != expected or attempt > max_attempts or (event == "sent") != (expected == 1):
                raise ValueError(f"{profile}: invalid event {event} for sequence {seq}")
            attempts[seq] = attempt
            if event == "sent":
                first_sent[seq] = at_ms
            else:
                retransmit_count += 1
        elif event in ("acknowledged", "failed"):
            if attempt != attempts.get(seq) or (event == "failed" and attempt != max_attempts):
                raise ValueError(f"{profile}: invalid terminal event for sequence {seq}")
            outcomes[seq] = event
            terminal_rtos.append(rto_ms)
            if event == "acknowledged":
                time_to_ack = metric_value(row["time_to_ack_ms"])
                if not math.isclose(time_to_ack, at_ms - first_sent[seq], abs_tol=2e-6):
                    raise ValueError(f"{profile}: ACK time disagrees with send and receive timestamps")
                ack_times.append(time_to_ack)
        else:
            raise ValueError(f"{profile}: unknown event {event!r}")
    if len(attempts) != count or attempts.keys() != outcomes.keys() or rows[-1]["event"] != "final":
        raise ValueError(f"{profile}: experiment ended without one terminal outcome per sent command")

    # Независимо проверяем, что повтор на сервере не вызвал повторного игрового события.
    applied = Counter(map(int, APPLIED_COMMAND.findall(server_log)))
    duplicates = len(DUPLICATE_COMMAND.findall(server_log))
    decisions = ACK_DECISION.findall(server_log)
    acknowledged = {seq for seq, event in outcomes.items() if event == "acknowledged"}
    if any(times != 1 for times in applied.values()) or not acknowledged <= applied.keys() <= attempts.keys():
        raise ValueError(f"{profile}: server command log disagrees with acknowledged sequences")
    if len(decisions) != len(applied) + duplicates:
        raise ValueError(f"{profile}: server did not attempt one ACK per new or duplicate command")
    first = sum(attempts[seq] == 1 for seq in acknowledged)
    failed = count - len(acknowledged)
    return {
        "profile": profile, "sent": count, "first": first, "failed": failed,
        "retransmit": retransmit_count, "mean_attempts": statistics.mean(attempts.values()),
        "mean_rto_ms": statistics.mean(terminal_rtos), "end_rto_ms": timeline[-1][1],
        "mean_ack_ms": statistics.mean(ack_times) if ack_times else None,
        "applied": len(applied), "duplicates": duplicates,
        "ack_decisions": len(decisions), "ack_drops": decisions.count("1"),
        "timeline": timeline,
    }


def render(results, directory):
    import matplotlib

    matplotlib.use("Agg")
    import matplotlib.pyplot as plt

    plt.rcParams.update({
        "font.family": "DejaVu Sans", "font.size": 10.5,
        "axes.spines.top": False, "axes.spines.right": False, "axes.axisbelow": True,
        "axes.labelcolor": "#25354d", "axes.edgecolor": "#a4afbf",
        "xtick.color": "#25354d", "ytick.color": "#25354d",
    })
    blue = "#1757a6"
    # У первых четырёх серий меняются только потери. Смешанные серии исказили бы это сравнение.
    loss = [0, 5, 10, 20]
    means = [item["mean_attempts"] for item in results[:4]]
    fig, ax = plt.subplots(figsize=(8.6, 4.3), layout="constrained")
    ax.plot(loss, means, marker="o", color=blue, linewidth=2.1)
    for percent, mean in zip(loss, means):
        ax.annotate(f"{mean:.2f}", (percent, mean), xytext=(0, 9), textcoords="offset points",
                    ha="center", color=blue)
    ax.set(title="Число попыток при потере подтверждений", xlabel="Настроенная вероятность потери ACK, %",
           ylabel="Среднее число попыток", xlim=(-1.2, 21.2), ylim=(0.97, max(means) + 0.12), xticks=loss)
    ax.grid(axis="y", color="#dfe5ed")
    fig.savefig(directory / CHARTS[0], dpi=180)
    plt.close(fig)

    timeline = results[-1]["timeline"]
    times = [at_ms / 1000 for at_ms, _ in timeline]
    rtos = [rto_ms for _, rto_ms in timeline]
    fig, ax = plt.subplots(figsize=(8.6, 4.3), layout="constrained")
    ax.axhline(100, color="#8291a6", linestyle="--", linewidth=1, label="Нижняя граница RTO")
    ax.step(times, rtos, where="post", color=blue, linewidth=1.7, label="Текущее RTO")
    ax.set(title="Изменение RTO при джиттере и потере ACK 10%", xlabel="Время от начала серии, с",
           ylabel="RTO, мс", ylim=(80, max(rtos) * 1.1))
    ax.grid(axis="y", color="#dfe5ed")
    ax.legend(loc="best", frameon=False)
    fig.savefig(directory / CHARTS[1], dpi=180)
    plt.close(fig)


def markdown_table(results):
    yield ("| Серия | Отправлено | ACK с 1-й попытки | Повторы | Failed | Ср. попыток | "
           "Ср. RTO, мс | RTO в конце, мс | Ср. время до ACK, мс |")
    yield "|---|---:|---:|---:|---:|---:|---:|---:|---:|"
    for m in results:
        sent = m["sent"]
        mean_ack = "—" if m["mean_ack_ms"] is None else f"{m['mean_ack_ms']:.2f}"
        yield (f"| `{m['profile']}` | {sent} | {m['first']} ({m['first'] / sent:.1%}) | {m['retransmit']} | "
               f"{m['failed']} ({m['failed'] / sent:.1%}) | {m['mean_attempts']:.2f} | "
               f"{m['mean_rto_ms']:.2f} | {m['end_rto_ms']:.2f} | {mean_ack} |")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--bin-dir", type=Path, required=True)
    parser.add_argument("--output-dir", type=Path, required=True)
    parser.add_argument("--count", type=int, default=100)
    parser.add_argument("--interval-ms", type=int, default=100)
    parser.add_argument("--ping-interval-ms", type=int, default=500)
    parser.add_argument("--max-attempts", type=int, default=5)
    parser.add_argument("--port", type=int, default=27015)
    parser.add_argument("--seed", type=int, default=20261031)
    args = parser.parse_args()
    if not (50 <= args.count <= 60000 and 20 <= args.interval_ms <= 1000
            and 100 <= args.ping_interval_ms <= 10000 and 1 <= args.max_attempts <= 10
            and 1 <= args.port <= 65535 and 1 <= args.seed <= 0xFFFFFFFF):
        parser.error("experiment parameters outside supported ranges")
    server, client = server_and_client(args.bin_dir)
    if not server.is_file() or not client.is_file():
        parser.error("build the client and server first")
    output = args.output_dir.resolve()
    samples = output / "reliability_samples.csv"
    if samples.exists() or any((output / "graphs" / name).exists() for name in CHARTS):
        parser.error("output already contains a PR3 experiment; choose a fresh --output-dir")
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as probe:
        probe.bind(("127.0.0.1", args.port))

    print("Experiment started", datetime.now(MOSCOW).isoformat(timespec="seconds"), flush=True)
    output.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix=".pr3-", dir=output) as path:
        directory = Path(path)
        server_evidence = {profile: run_series(server, client, directory, profile, args) for profile in PROFILES}
        rows = read_series(directory / samples.name)
        if set(rows) != {(profile, run_id) for profile, (run_id, _) in server_evidence.items()}:
            raise ValueError("event CSV series and run IDs do not match the executed series")
        results = [analyze_series(profile, rows[profile, run_id], args.count, args.max_attempts, server_log)
                   for profile, (run_id, server_log) in server_evidence.items()]
        render(results, directory)
        # Публикуем измерения после завершения всех серий и проверки данных.
        (output / "graphs").mkdir(exist_ok=True)
        (directory / samples.name).replace(samples)
        for name in CHARTS:
            (directory / name).replace(output / "graphs" / name)
    print("Experiment finished", datetime.now(MOSCOW).isoformat(timespec="seconds"))
    print("\n".join(markdown_table(results)))
    for m in results:
        print(f"SERVER {m['profile']} applied={m['applied']} duplicates={m['duplicates']} "
              f"ack_drops={m['ack_drops']}/{m['ack_decisions']}")


if __name__ == "__main__":
    main()
