"""Pick key frames from the NET LAB experiment captures and write captioned
screenshots + the three required videos into docs/media.

    python kart/tools/netlab/make_media.py --frames C:/tmp/netlab_frames
"""
from __future__ import annotations

import argparse
import csv
import re
import shutil
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

ROOT = Path(__file__).resolve().parents[3]
LOGS = ROOT / "docs" / "prediction_logs"
MEDIA = ROOT / "docs" / "media"
FONT = "C:/Windows/Fonts/arialbd.ttf"


def events(name: str, side: str = "client") -> list[dict]:
    with (LOGS / f"{name}_{side}.csv").open(encoding="utf-8") as f:
        rows = list(csv.DictReader(f))
    for r in rows:
        r["wall"] = int(r["wall_ms"])
        r["kv"] = dict(re.findall(r"(\w+)=([^ ]+)", r["details"]))
    return rows


def frame_at(frames: Path, name: str, side: str, wall: int) -> Path:
    files = sorted((frames / name / side).glob("f_*.jpg"), key=lambda p: int(p.stem[2:]))
    after = [p for p in files if int(p.stem[2:]) >= wall]  # first frame at/after the moment
    return after[0] if after else files[-1]


def captioned(paths: list[Path], labels: list[str], caption: str, out: Path) -> None:
    imgs = [Image.open(p).convert("RGB") for p in paths]
    w, h = imgs[0].size
    bar = 64
    canvas = Image.new("RGB", (w * len(imgs), h + bar), (20, 16, 24))
    d = ImageDraw.Draw(canvas)
    small = ImageFont.truetype(FONT, 20)
    big = ImageFont.truetype(FONT, 22)
    for k, (im, lab) in enumerate(zip(imgs, labels)):
        canvas.paste(im, (k * w, 0))
        tw = d.textlength(lab, font=small)
        d.rectangle([k * w + w - tw - 22, h - 34, k * w + w - 6, h - 6], fill=(236, 43, 58))
        d.text((k * w + w - tw - 14, h - 31), lab, font=small, fill=(255, 246, 220))
    d.text((16, h + 18), caption, font=big, fill=(255, 210, 31))
    out.parent.mkdir(parents=True, exist_ok=True)
    canvas.save(out)
    print("wrote", out.relative_to(ROOT))


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--frames", required=True, type=Path)
    fr = ap.parse_args().frames
    MEDIA.mkdir(parents=True, exist_ok=True)

    # T1: plain movement, client vs server at the same moment.
    ev = events("T1")
    t = next(r["wall"] for r in ev if r["event"] == "dash_press") - 600
    captioned([frame_at(fr, "T1", "client", t), frame_at(fr, "T1", "server", t)], ["CLIENT", "SERVER"],
              "T1: без эмуляции. Клиент и сервер видят одно и то же, коррекций 0.", MEDIA / "T1_movement.png")

    # T2: baseline — press, then nothing, then the server's dash arrives.
    ev = events("T2")
    press = [r for r in ev if r["event"] == "dash_press"][1]
    react = next(r for r in ev if r["event"] == "dash_reaction" and r["wall"] > press["wall"])
    captioned([frame_at(fr, "T2", "client", press["wall"] + 40),
               frame_at(fr, "T2", "client", press["wall"] + 160),
               frame_at(fr, "T2", "client", react["wall"] + 70)],
              ["0 ms: SPACE pressed", "+160 ms: still nothing", "+%s ms: server dash arrives" % react["kv"]["latency_ms"].split(".")[0]],
              "T2 / без предсказания (RPC), 100 мс в каждую сторону: рывок виден только через ~RTT; машина «прыгает» вперёд коррекцией.",
              MEDIA / "baseline_no_prediction.png")

    # T3: CSP — the dash is on screen in the same frame.
    ev = events("T3")
    press = [r for r in ev if r["event"] == "dash_press"][1]
    captioned([frame_at(fr, "T3", "client", press["wall"] + 40),
               frame_at(fr, "T3", "server", press["wall"] + 40),
               frame_at(fr, "T3", "server", press["wall"] + 260)],
              ["CLIENT +0 ms: DASH!", "SERVER +0 ms: not yet", "SERVER +~150 ms: confirmed"],
              "T3 / с предсказанием, 100 мс: клиент рывок показывает сразу, сервер применяет его позже сам и не делает коррекцию.",
              MEDIA / "prediction_enabled.png")

    # T4: bad network, both phases.
    ev = events("T4")
    presses = [r for r in ev if r["event"] == "dash_press"]
    csp = presses[2]
    rpc = next(r for r in presses if r["kv"].get("mode") == "RPC")
    blocked = next((r for r in ev if r["event"] == "client_dash_blocked_locally"), csp)
    captioned([frame_at(fr, "T4", "client", csp["wall"] + 40),
               frame_at(fr, "T4", "client", blocked["wall"] + 120),
               frame_at(fr, "T4", "client", rpc["wall"] + 200)],
              ["CSP: instant", "inside cooldown: WAIT", "RPC: +200 ms nothing yet"],
              "T4: 175±25 мс, 5% потерь. Ввод идёт с избыточностью, позиционных коррекций нет; рывок в кулдауне сервер не принимает.",
              MEDIA / "T4_bad_network.png")

    # T5: deliberate divergence -> authoritative correction.
    ev = events("T5")
    corr = next(r for r in ev if r["event"] == "client_correction" and r["kv"].get("why") == "dash_state")
    captioned([frame_at(fr, "T5", "client", corr["wall"] - 120),
               frame_at(fr, "T5", "client", corr["wall"] + 130),
               frame_at(fr, "T5", "server", corr["wall"] - 120)],
              ["client predicted cheat dash", "server said NO -> corrected", "SERVER log: 2nd dash REJECTED"],
              "T5: клиент с читом игнорирует кулдаун. Сервер отклоняет рывок, клиент откатывается на %s м к авторитетному состоянию." % corr["kv"]["snap_m"],
              MEDIA / "correction_example.png")
    speed = next((r for r in ev if r["event"] == "client_correction" and float(r["kv"]["snap_m"]) > 0.5
                  and r["wall"] > corr["wall"] + 4000), None)
    if speed:
        captioned([frame_at(fr, "T5", "client", speed["wall"] - 100), frame_at(fr, "T5", "client", speed["wall"] + 100)],
                  ["speed/time cheat", "pulled back by server"],
                  "T5: «спидхак» на клиенте (SpeedMult / DoubleTick): сервер считает по своим правилам, клиента тянет назад.",
                  MEDIA / "correction_speedhack.png")

    for src, dst in (("T2", "baseline_no_prediction.mp4"), ("T3", "prediction_enabled.mp4"), ("T5", "correction_example.mp4")):
        shutil.copy(fr / f"{src}.mp4", MEDIA / dst)
        print("copied", dst)


if __name__ == "__main__":
    main()
