"""Reproducible NET LAB experiments for practical work #4 (T1..T5).

For every test it starts a listen server and a client (two Godot windows),
drives the client with a scripted timeline (autodrive + dash presses + cheats),
collects both CSV logs and captured frames, then computes the metrics and
builds side-by-side videos (client | server).

Usage (from the repo root):
    python kart/tools/netlab/run_prediction_tests.py --godot C:/path/Godot_v4.4.1-stable_win64.exe \
        --frames C:/tmp/netlab_frames [--only T2,T3] [--no-video]
"""
from __future__ import annotations

import argparse
import csv
import json
import re
import statistics
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
PROJECT = ROOT / "kart"
LOGS = ROOT / "docs" / "prediction_logs"
MEDIA = ROOT / "docs" / "media"

DASHES = [2.5, 4.5, 6.5, 8.5, 10.5, 12.5]

TESTS = {
    "T1": {
        "title": "T1  NO EMULATION - MOVEMENT",
        "profile": 0, "csp": 1, "duration": 12.0,
        "timeline": ["0.3 autodrive 1"] + [f"{t} dash" for t in (3.0, 6.0, 9.0)],
    },
    "T2": {
        "title": "T2  100 MS - DASH WITHOUT PREDICTION (RPC)",
        "profile": 1, "csp": 0, "duration": 14.5,
        "timeline": ["0.3 autodrive 1"] + [f"{t} dash" for t in DASHES],
    },
    "T3": {
        "title": "T3  100 MS - DASH WITH CLIENT-SIDE PREDICTION",
        "profile": 1, "csp": 1, "duration": 14.5,
        "timeline": ["0.3 autodrive 1"] + [f"{t} dash" for t in DASHES],
    },
    "T4": {
        "title": "T4  175+-25 MS, 5% LOSS - MOVEMENT + DASH",
        "profile": 2, "csp": 1, "duration": 20.5,
        "timeline": ["0.3 autodrive 1"]
        + [f"{t} dash" for t in DASHES]
        + ["7.2 dash"]  # inside the cooldown: honest client blocks it itself
        + ["13.5 net.DashPrediction 0"]
        + [f"{t} dash" for t in (15.0, 17.0, 19.0)],
    },
    "T5": {
        "title": "T5  175+-25 MS, 5% LOSS - DELIBERATE DIVERGENCE",
        "profile": 2, "csp": 1, "duration": 17.5,
        "timeline": [
            "0.3 autodrive 1",
            "2.0 cheat.IgnoreCooldown 1",
            "3.0 dash", "3.5 dash", "4.0 dash",
            "6.0 cheat.IgnoreCooldown 0",
            "7.0 cheat.SpeedMult 1.6",
            "10.0 cheat.SpeedMult 1",
            "11.5 cheat.DoubleTick 1",
            "13.5 cheat.DoubleTick 0",
            "15.0 dash",
        ],
    },
}


def run_test(name: str, cfg: dict, godot: str, frames: Path, port: int, video: bool) -> None:
    tdir = frames / name
    for sub in ("client", "server"):
        d = tdir / sub
        d.mkdir(parents=True, exist_ok=True)
        for f in d.glob("*.jpg"):
            f.unlink()
    LOGS.mkdir(parents=True, exist_ok=True)
    tl_client = tdir / "timeline_client.txt"
    lines = cfg["timeline"] + ["%.1f stats" % (cfg["duration"] - 0.4), "%.1f quit" % cfg["duration"]]
    tl_client.write_text("\n".join(lines) + "\n", encoding="utf-8")
    tl_server = tdir / "timeline_server.txt"
    tl_server.write_text("0.2 autodrive 1\n%.1f quit\n" % (cfg["duration"] + 6.0), encoding="utf-8")
    (LOGS / f"{name}_timeline_client.txt").write_text(tl_client.read_text(encoding="utf-8"), encoding="utf-8")

    common = [godot, "--path", str(PROJECT), "--resolution", "960x540"]
    cap = ["--capture-fps=15"] if video else []
    server_cmd = common + ["--position", "975,60", "--", "--netlab", "--host", f"--port={port}",
                           f"--timeline={tl_server}", f"--log={LOGS / (name + '_server.csv')}",
                           "--caption=SERVER VIEW (authority)", "--cam-client"] + ([f"--capture={tdir / 'server'}"] + cap if video else [])
    client_cmd = common + ["--position", "5,60", "--", "--netlab", "--client", f"--port={port}",
                           f"--profile={cfg['profile']}", f"--csp={cfg['csp']}", "--seed=4242",
                           f"--timeline={tl_client}", f"--log={LOGS / (name + '_client.csv')}",
                           f"--caption={cfg['title']}"] + ([f"--capture={tdir / 'client'}"] + cap if video else [])
    print(f"[{name}] starting server + client ...", flush=True)
    server = subprocess.Popen(server_cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    time.sleep(2.5)
    client = subprocess.Popen(client_cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    try:
        client.wait(timeout=cfg["duration"] + 40)
    finally:
        if client.poll() is None:
            client.kill()
        time.sleep(0.5)
        server.kill()
    print(f"[{name}] done", flush=True)


def read_log(path: Path) -> list[dict]:
    if not path.exists():
        return []
    with path.open(encoding="utf-8") as f:
        rows = list(csv.DictReader(f))
    for r in rows:
        r["kv"] = dict(re.findall(r"(\w+)=([^ ]+)", r["details"]))
    return rows


def analyse(name: str) -> dict:
    cl = read_log(LOGS / f"{name}_client.csv")
    sv = read_log(LOGS / f"{name}_server.csv")
    lat = {"CSP": [], "RPC": []}
    for r in cl:
        if r["event"] == "dash_reaction":
            lat[r["kv"]["mode"]].append(float(r["kv"]["latency_ms"]))
    corr = [r for r in cl if r["event"] == "client_correction"]
    rtts = [float(r["kv"]["rtt_ms"]) for r in cl if r["event"] == "dash_reaction" and r["kv"]["rtt_ms"] != "-1.0"]
    stats_row = next((r for r in reversed(cl) if r["event"] == "quit"), None)
    out = {
        "test": name,
        "dash_presses": sum(1 for r in cl if r["event"] == "dash_press"),
        "dash_latency_csp_ms": [round(x, 1) for x in lat["CSP"]],
        "dash_latency_rpc_ms": [round(x, 1) for x in lat["RPC"]],
        "dash_latency_csp_avg_ms": round(statistics.mean(lat["CSP"]), 1) if lat["CSP"] else None,
        "dash_latency_rpc_avg_ms": round(statistics.mean(lat["RPC"]), 1) if lat["RPC"] else None,
        "rtt_ms_avg": round(statistics.mean(rtts), 1) if rtts else None,
        "corrections": len(corr),
        "corrections_dash_state": sum(1 for r in corr if r["kv"].get("why") == "dash_state"),
        "max_snap_m": max((float(r["kv"]["snap_m"]) for r in corr), default=0.0),
        "blocked_locally": sum(1 for r in cl if r["event"] == "client_dash_blocked_locally"),
        "server_dash_accept": sum(1 for r in sv if r["event"] == "server_dash_accept"),
        "server_dash_reject": sum(1 for r in sv if r["event"] == "server_dash_reject"),
        "server_move_budget_rejects": max((int(r["kv"]["total"]) for r in sv if r["event"] == "server_reject_move"), default=0),
        "client_disconnected": any(r["event"] == "server_disconnected" for r in cl),
        "client_stats": stats_row["kv"] if stats_row else {},
    }
    return out


def build_video(name: str, frames: Path, out: Path) -> None:
    import imageio.v2 as imageio
    from PIL import Image, ImageDraw

    cdir, sdir = frames / name / "client", frames / name / "server"
    cf = sorted(cdir.glob("f_*.jpg"), key=lambda p: int(p.stem[2:]))
    sf = sorted(sdir.glob("f_*.jpg"), key=lambda p: int(p.stem[2:]))
    if not cf:
        print(f"[{name}] no frames")
        return
    st = [int(p.stem[2:]) for p in sf]
    w, h = 720, 406
    writer = imageio.get_writer(out, fps=15, codec="libx264", quality=6, macro_block_size=2)
    for p in cf:
        t = int(p.stem[2:])
        canvas = Image.new("RGB", (w * 2, h), (20, 16, 24))
        canvas.paste(Image.open(p).convert("RGB").resize((w, h)), (0, 0))
        if st:
            j = min(range(len(st)), key=lambda k: abs(st[k] - t))
            canvas.paste(Image.open(sf[j]).convert("RGB").resize((w, h)), (w, 0))
        d = ImageDraw.Draw(canvas)
        d.rectangle([0, h - 22, 150, h], fill=(20, 16, 24))
        d.text((6, h - 18), "CLIENT", fill=(255, 210, 31))
        d.rectangle([w, h - 22, w + 220, h], fill=(20, 16, 24))
        d.text((w + 6, h - 18), "LISTEN SERVER", fill=(63, 224, 232))
        writer.append_data(__import__("numpy").asarray(canvas))
    writer.close()
    print(f"[{name}] video -> {out}")


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--godot", required=True)
    ap.add_argument("--frames", required=True, type=Path)
    ap.add_argument("--only", default="")
    ap.add_argument("--no-video", action="store_true")
    ap.add_argument("--analyse-only", action="store_true")
    a = ap.parse_args()
    names = [n for n in TESTS if not a.only or n in a.only.split(",")]
    if not a.analyse_only:
        for k, n in enumerate(names):
            run_test(n, TESTS[n], a.godot, a.frames, 27300 + k, not a.no_video)
    results = {n: analyse(n) for n in TESTS if (LOGS / f"{n}_client.csv").exists()}
    (LOGS / "summary.json").write_text(json.dumps(results, indent=2, ensure_ascii=False), encoding="utf-8")
    for n, r in results.items():
        print(n, json.dumps({k: v for k, v in r.items() if k != "client_stats"}, ensure_ascii=False))
    if not a.no_video:
        MEDIA.mkdir(parents=True, exist_ok=True)
        for n in names:
            build_video(n, a.frames, a.frames / f"{n}.mp4")
    return 0


if __name__ == "__main__":
    sys.exit(main())
