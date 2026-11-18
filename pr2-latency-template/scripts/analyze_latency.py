"""Validate event CSV, independently recompute metrics, and render static graphs."""

import argparse
import csv
from collections import defaultdict
import json
import math
from pathlib import Path
import statistics

PROFILES = ("baseline", "delay_50", "delay_100", "jitter", "loss_5", "combined")
STATUSES = {
    "received",
    "timeout",
    "late_response",
    "duplicate_response",
    "unknown_response",
    "invalid_response",
}


def number(value):
    result = float(value)
    if not math.isfinite(result) or result < 0:
        raise ValueError("non-finite or negative measurement")
    return result


def analyze_rows(rows):
    # Группируем события по серии и запуску, чтобы история измерений и SRTT не смешивались.
    groups = defaultdict(list)
    for row in rows:
        if row["status"] not in STATUSES:
            raise ValueError("unknown CSV status: " + row["status"])
        if row["status"] != "received" and (row["rtt_ms"] or row["srtt_ms"]):
            raise ValueError("non-received event contains a successful metric")
        groups[(row["experiment_id"], row["run_id"])].append(row)
    results = []
    for (experiment, run), events in groups.items():
        terminal = {}
        rtts = []
        srtt = None
        late = set()
        counts = defaultdict(int)
        for index, row in enumerate(events, 1):
            if int(row["event_index"]) != index:
                raise ValueError("event sequence is not contiguous")
            status = row["status"]
            counts[status] += 1
            # Для каждого отправленного PING учитываем один итог, своевременный ответ или тайм-аут.
            if status in ("received", "timeout"):
                sample = int(row["sample"])
                if sample in terminal:
                    raise ValueError("double-counted terminal outcome")
                if int(row["attempts"]) != 1:
                    raise ValueError("PR2 must not retransmit")
                terminal[sample] = row
            if status == "late_response":
                sample = int(row["sample"])
                if sample not in terminal or terminal[sample]["status"] != "timeout" or sample in late:
                    raise ValueError("late response must follow exactly one timeout")
                late.add(sample)
            if status == "received":
                # Пересчитываем RTT из клиентских меток, а SRTT — из последовательности принятых RTT.
                rtt = number(row["rtt_ms"])
                sent = number(row["sent_at_ms"])
                received = number(row["received_at_ms"])
                if not math.isclose(rtt, received - sent, abs_tol=2e-6):
                    raise ValueError("RTT differs from client timestamp difference")
                srtt = rtt if srtt is None else 0.875 * srtt + 0.125 * rtt
                if not math.isclose(number(row["srtt_ms"]), srtt, abs_tol=2e-6):
                    raise ValueError("logged SRTT differs from independent calculation")
                rtts.append(rtt)
        sent = len(terminal)
        if set(terminal) != set(range(1, sent + 1)):
            raise ValueError("missing sample numbers or incomplete run")
        metrics = dict(
            experiment_id=experiment,
            run_id=run,
            sent=sent,
            received=len(rtts),
            timeouts=counts["timeout"],
            late=counts["late_response"],
            duplicates=counts["duplicate_response"],
            unknown=counts["unknown_response"],
            invalid=counts["invalid_response"],
            min_ms=min(rtts) if rtts else None,
            max_ms=max(rtts) if rtts else None,
            mean_ms=statistics.mean(rtts) if rtts else None,
            median_ms=statistics.median(rtts) if rtts else None,
            srtt_ms=srtt,
            jitter_ms=statistics.mean(abs(b - a) for a, b in zip(rtts, rtts[1:])) if len(rtts) > 1 else 0,
            loss_percent=100 * counts["timeout"] / sent if sent else 0,
        )
        if sent != metrics["received"] + metrics["timeouts"]:
            raise ValueError("inconsistent outcome totals")
        results.append((metrics, events))
    if not results:
        raise ValueError("empty experiment")
    return results


def markdown_table(results):
    table = [
        "| Серия | Отправлено | Получено | Тайм-ауты | Late | Min, мс | Mean, мс | Median, мс | Max, мс | SRTT, мс | Jitter, мс | Loss, % |",
        "|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|",
    ]
    for metric, _ in results:

        def fmt(key):
            value = metric[key]
            return "—" if value is None else f"{value:.3f}"

        table.append(
            f"| {metric['experiment_id']} | {metric['sent']} | {metric['received']} | {metric['timeouts']} | {metric['late']} | "
            + " | ".join(
                fmt(key)
                for key in (
                    "min_ms",
                    "mean_ms",
                    "median_ms",
                    "max_ms",
                    "srtt_ms",
                    "jitter_ms",
                    "loss_percent",
                )
            )
            + " |"
        )
    return "\n".join(table) + "\n"


def render(results, output):
    import matplotlib

    matplotlib.use("Agg")
    import matplotlib.pyplot as plt

    plt.rcParams.update(
        {"font.family": "DejaVu Sans", "font.size": 10, "axes.spines.top": False, "axes.spines.right": False}
    )
    output.mkdir(parents=True, exist_ok=True)
    fig, axes = plt.subplots(3, 2, figsize=(12, 9), layout="constrained")
    for ax, (metric, events) in zip(axes.flat, results):
        successful = {int(row["sample"]): row for row in events if row["status"] == "received"}
        samples = list(range(1, metric["sent"] + 1))
        # NaN оставляет разрыв в линии. Крест указывает номер пробы, его высота условна.
        ax.plot(
            samples,
            [float(successful[i]["rtt_ms"]) if i in successful else math.nan for i in samples],
            "-o",
            ms=3,
            label="RTT",
            color="#2563eb",
        )
        ax.plot(
            samples,
            [float(successful[i]["srtt_ms"]) if i in successful else math.nan for i in samples],
            "--",
            label="SRTT",
            color="#059669",
        )
        lost = [int(row["sample"]) for row in events if row["status"] == "timeout"]
        if lost:
            ax.scatter(
                lost,
                [0.94] * len(lost),
                transform=ax.get_xaxis_transform(),
                marker="x",
                color="#dc2626",
                label="timeout (marker only)",
            )
        ax.set(title=metric["experiment_id"], xlabel="PING sample", ylabel="Milliseconds")
        ax.grid(alpha=0.2)
        ax.legend(fontsize=8, loc="best")
    fig.suptitle("Measured UDP RTT and SRTT; timeout markers have no RTT value")
    fig.savefig(output / "rtt_series.png", dpi=180)
    plt.close(fig)
    # Задержку показываем в миллисекундах, а долю тайм-аутов — в процентах на отдельном графике.
    names = [m["experiment_id"] for m, _ in results]
    x = list(range(len(results)))
    fig, axes = plt.subplots(2, 1, figsize=(11, 7), layout="constrained")
    axes[0].bar(
        [v - 0.18 for v in x],
        [m["mean_ms"] or 0 for m, _ in results],
        0.36,
        label="Mean RTT",
        color="#2563eb",
    )
    axes[0].bar(
        [v + 0.18 for v in x],
        [m["srtt_ms"] or 0 for m, _ in results],
        0.36,
        label="Final SRTT",
        color="#059669",
    )
    axes[0].set_xticks(x, names)
    axes[0].set_ylabel("Milliseconds")
    axes[0].legend()
    values = [m["loss_percent"] for m, _ in results]
    axes[1].bar(x, values, color="#dc2626")
    axes[1].set_xticks(x, names)
    axes[1].set_ylabel("Timeouts / sent, %")
    axes[1].set_ylim(0, max(10, max(values) * 1.3))
    for pos, value in zip(x, values):
        axes[1].text(pos, value + 0.2, f"{value:.1f}%", ha="center")
    for ax in axes:
        ax.grid(axis="y", alpha=0.2)
    fig.suptitle("Series comparison; milliseconds and percentages use separate axes")
    fig.savefig(output / "series_comparison.png", dpi=180)
    plt.close(fig)
    # Box plot показывает распределение только измеренных RTT. Долю потерь указываем в подписи.
    selected = [(m, e) for m, e in results if m["experiment_id"] in ("baseline", "jitter", "combined")]
    fig, ax = plt.subplots(figsize=(8, 5), layout="constrained")
    ax.boxplot(
        [[number(r["rtt_ms"]) for r in events if r["status"] == "received"] for _, events in selected],
        tick_labels=[
            f"{m['experiment_id']}\nn={m['received']}; loss={m['loss_percent']:.1f}%" for m, _ in selected
        ],
        showmeans=True,
    )
    ax.set(title="RTT distribution of successful responses only", ylabel="Milliseconds")
    ax.grid(axis="y", alpha=0.2)
    fig.savefig(output / "rtt_distribution.png", dpi=180)
    plt.close(fig)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--docs", type=Path, default=Path(__file__).resolve().parents[1] / "docs")
    args = parser.parse_args()
    docs = args.docs
    with (docs / "latency_samples.csv").open(encoding="utf-8", newline="") as file:
        results = analyze_rows(list(csv.DictReader(file, delimiter=";")))
    manifest = json.loads((docs / "experiment_manifest.json").read_text(encoding="utf-8"))
    if not manifest["completed"] or [m["experiment_id"] for m, _ in results] != list(PROFILES):
        raise ValueError("all six completed series are required")
    # Перед построением графиков сверяем расчёты из CSV с итогами клиента из manifest.
    for (metric, _), series in zip(results, manifest["series"]):
        if metric["sent"] < 50:
            raise ValueError("fewer than 50 PING")
        for key in (
            "sent",
            "received",
            "timeouts",
            "late",
            "duplicates",
            "unknown",
            "min_ms",
            "max_ms",
            "mean_ms",
            "median_ms",
            "srtt_ms",
            "jitter_ms",
            "loss_percent",
        ):
            expected = series["summary"][key]
            actual = metric[key]
            if actual is None or expected is None:
                if actual != expected:
                    raise ValueError("summary null mismatch: " + key)
            elif not math.isclose(actual, expected, abs_tol=2e-6):
                raise ValueError("client/CSV mismatch: " + key)
    (docs / "metrics.json").write_text(json.dumps([m for m, _ in results], indent=2) + "\n", encoding="utf-8")
    table = markdown_table(results)
    (docs / "metrics_table.md").write_text(table, encoding="utf-8")
    report = docs / "Latency_Report.md"
    if report.exists():
        text = report.read_text(encoding="utf-8")
        if "<!-- metrics:start -->" in text and "<!-- metrics:end -->" in text:
            before = text.split("<!-- metrics:start -->")[0]
            after = text.split("<!-- metrics:end -->", 1)[1]
            report.write_text(
                before + "<!-- metrics:start -->\n" + table + "<!-- metrics:end -->" + after, encoding="utf-8"
            )
    render(results, docs / "graphs")
    print(table)


if __name__ == "__main__":
    main()
