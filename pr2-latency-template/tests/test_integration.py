"""Real UDP tests. No emulator results are substituted for actual socket traffic."""

import argparse
import csv
import json
import os
from pathlib import Path
import socket
import struct
import subprocess
import tempfile
import threading
import time
import unittest

PARSER = argparse.ArgumentParser()
PARSER.add_argument("--client", required=True)
PARSER.add_argument("--server", required=True)
ARGS, REST = PARSER.parse_known_args()
FLAGS = subprocess.CREATE_NO_WINDOW if os.name == "nt" else 0


def available_port():
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]


def summary(result):
    return json.loads(next(line[8:] for line in result.stdout.splitlines() if line.startswith("SUMMARY ")))


def pong(seq, echo, version=2):
    return struct.pack("!BHHHBQQQ", 2, seq, 24, version, 0, echo, 10, 20)


class UdpTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)

    def tearDown(self):
        self.temp.cleanup()

    def client(self, port, count=4, timeout=80, grace=200, extra=()):
        return subprocess.run(
            [
                ARGS.client,
                "--port",
                str(port),
                "--count",
                str(count),
                "--interval-ms",
                "200",
                "--timeout-ms",
                str(timeout),
                "--grace-ms",
                str(grace),
                "--csv",
                str(self.root / "samples.csv"),
                "--run-id",
                "integration",
                *extra,
            ],
            capture_output=True,
            text=True,
            timeout=8,
            creationflags=FLAGS,
        )

    def test_invalid_cli_and_csv_fail_before_measurement(self):
        for extra in [
            ("--count", "0"),
            ("--count", "-1"),
            ("--interval-ms", "199"),
            ("--port", "65536"),
            ("--count", "1.2"),
            ("--experiment", "bad;id"),
            ("--unknown", "1"),
            ("--count",),
        ]:
            run = subprocess.run([ARGS.client, *extra], capture_output=True, timeout=3, creationflags=FLAGS)
            self.assertNotEqual(run.returncode, 0, extra)
        path = self.root / "samples.csv"
        path.write_text("wrong;header\n", encoding="utf-8")
        result = self.client(available_port(), count=1)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(path.read_text(), "wrong;header\n")

    def test_absent_server_finishes_with_exact_loss(self):
        result = self.client(available_port(), count=2, grace=0)
        self.assertEqual(result.returncode, 0, result.stderr)
        data = summary(result)
        self.assertEqual((data["sent"], data["received"], data["timeouts"]), (2, 0, 2))
        self.assertEqual(data["loss_percent"], 100)
        self.assertIsNone(data["mean_ms"])

    def test_duplicate_run_id_preserves_existing_csv(self):
        first = self.client(available_port(), count=1, timeout=20, grace=0)
        self.assertEqual(first.returncode, 0, first.stderr)
        path = self.root / "samples.csv"
        original = path.read_bytes()
        second = self.client(available_port(), count=1, timeout=20, grace=0)
        self.assertNotEqual(second.returncode, 0)
        self.assertIn("run-id already present", second.stderr)
        self.assertEqual(path.read_bytes(), original)

    def test_faults_late_duplicates_and_constant_send_interval(self):
        sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        sock.bind(("127.0.0.1", 0))
        sock.settimeout(0.01)
        stop = threading.Event()
        errors = []
        times = []

        def responder():
            scheduled = []
            try:
                while not stop.is_set():
                    now = time.monotonic()
                    for item in list(scheduled):
                        if item[0] <= now:
                            sock.sendto(item[1], item[2])
                            scheduled.remove(item)
                    try:
                        packet, address = sock.recvfrom(65536)
                    except socket.timeout:
                        continue
                    _, seq, _, _, _, echo = struct.unpack("!BHHHBQ", packet)
                    times.append(time.monotonic())
                    # В одном сценарии проверяем повреждённые и посторонние ответы, дубликаты, опоздание и потерю.
                    if seq == 0:
                        sock.sendto(pong(seq, echo, 1), address)
                        sock.sendto(struct.pack("!BHHHBQQQ", 2, seq, 24, 2, 0, echo, 20, 10), address)
                        sock.sendto(pong(seq, echo + 1), address)
                        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as foreign:
                            foreign.sendto(pong(seq, echo), address)
                        sock.sendto(pong(65000, echo), address)
                        sock.sendto(pong(seq, echo), address)
                        sock.sendto(pong(seq, echo), address)
                    elif seq == 1:
                        scheduled.extend(
                            [(now + 0.12, pong(seq, echo), address), (now + 0.14, pong(seq, echo), address)]
                        )
                    elif seq == 3:
                        sock.sendto(pong(seq, echo), address)
            except Exception as error:
                errors.append(error)

        worker = threading.Thread(target=responder)
        worker.start()
        try:
            result = self.client(sock.getsockname()[1])
        finally:
            stop.set()
            worker.join(2)
            sock.close()
        self.assertFalse(errors, errors)
        self.assertEqual(result.returncode, 0, result.stderr)
        data = summary(result)
        self.assertEqual((data["sent"], data["received"], data["timeouts"], data["late"]), (4, 2, 2, 1))
        self.assertEqual((data["duplicates"], data["unknown"], data["invalid"]), (2, 1, 4))
        self.assertEqual(data["loss_percent"], 50)
        self.assertEqual(len(times), 4)
        # Даже при пропущенных ответах клиент продолжает отправлять PING с интервалом около 200 мс.
        for a, b in zip(times, times[1:]):
            self.assertAlmostEqual(b - a, 0.2, delta=0.08)
        with (self.root / "samples.csv").open(newline="") as file:
            rows = list(csv.DictReader(file, delimiter=";"))
        terminal = [row for row in rows if row["status"] in ("received", "timeout")]
        self.assertEqual(len(terminal), 4)
        self.assertEqual(len({row["sample"] for row in terminal}), 4)
        self.assertTrue(all(not row["rtt_ms"] for row in rows if row["status"] != "received"))

    def test_reordered_pongs_are_both_accepted(self):
        sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        sock.bind(("127.0.0.1", 0))
        sock.settimeout(3)
        errors = []

        def responder():
            try:
                first, address = sock.recvfrom(65536)
                second, _ = sock.recvfrom(65536)
                for packet in (second, first):
                    _, seq, _, _, _, echo = struct.unpack("!BHHHBQ", packet)
                    sock.sendto(pong(seq, echo), address)
            except Exception as e:
                errors.append(e)

        worker = threading.Thread(target=responder)
        worker.start()
        try:
            result = self.client(sock.getsockname()[1], count=2, timeout=600, grace=0)
        finally:
            worker.join(4)
            sock.close()
        self.assertFalse(errors, errors)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(summary(result)["received"], 2)
        with (self.root / "samples.csv").open() as file:
            rows = list(csv.DictReader(file, delimiter=";"))
        self.assertEqual([row["sequence"] for row in rows], ["1", "0"])

    def test_dedicated_server_survives_invalid_datagrams(self):
        port = available_port()
        log = self.root / "server.txt"
        with log.open("w") as output:
            server = subprocess.Popen(
                [ARGS.server, "--port", str(port), "--duration-ms", "3000"],
                stdout=output,
                stderr=subprocess.STDOUT,
                creationflags=FLAGS,
            )
            try:
                deadline = time.monotonic() + 3
                while "READY " not in log.read_text() and time.monotonic() < deadline:
                    if server.poll() is not None:
                        self.fail(log.read_text())
                    time.sleep(0.01)
                with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock:
                    sock.settimeout(1)
                    for packet in (
                        b"",
                        b"\x01",
                        b"\xff" * 15,
                        struct.pack("!BHHHBff", 3, 1, 8, 2, 0, 1.0, 2.0),
                        struct.pack("!BHHHBffI", 4, 2, 12, 2, 0, 1.0, 0.0, 1),
                    ):
                        sock.sendto(packet, ("127.0.0.1", port))
                    sock.sendto(struct.pack("!BHHHBQ", 1, 42, 8, 2, 0, 1234), ("127.0.0.1", port))
                    packet, _ = sock.recvfrom(65536)
                    kind, seq, length, version, flags, echo, received, sent = struct.unpack(
                        "!BHHHBQQQ", packet
                    )
                    self.assertEqual((kind, seq, length, version, flags, echo), (2, 42, 24, 2, 0, 1234))
                    self.assertGreaterEqual(sent, received)
            finally:
                server.terminate()
                server.wait(timeout=3)
        self.assertIn("REJECT", log.read_text())
        self.assertIn("COMMAND type=3", log.read_text())

    def test_server_reacknowledges_duplicate_without_replaying_and_isolates_peers(self):
        port = available_port()
        log = self.root / "server.txt"
        with log.open("w") as output:
            server = subprocess.Popen(
                [ARGS.server, "--port", str(port)],
                stdout=output,
                stderr=subprocess.STDOUT,
                creationflags=FLAGS,
            )
            try:
                deadline = time.monotonic() + 3
                while "READY " not in log.read_text() and time.monotonic() < deadline:
                    if server.poll() is not None:
                        self.fail(log.read_text())
                    time.sleep(0.01)
                shoot = struct.pack("!BHHHBffI", 4, 17, 12, 2, 1, 1.0, 0.0, 1)
                ack = struct.pack("!BHHHBH", 5, 17, 2, 2, 0, 17)
                with (
                    socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as a,
                    socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as b,
                ):
                    # Два клиента могут использовать одинаковый sequence. Повтор A получает ACK снова.
                    for client in (a, a, b):
                        client.settimeout(1)
                        client.sendto(shoot, ("127.0.0.1", port))
                        self.assertEqual(client.recvfrom(256)[0], ack)
                deadline = time.monotonic() + 1
                while log.read_text().count("COMMAND type=4") < 2 and time.monotonic() < deadline:
                    time.sleep(0.01)
            finally:
                server.terminate()
                server.wait(timeout=3)
        lines = log.read_text()
        self.assertEqual(lines.count("COMMAND type=4 seq=17"), 2)
        self.assertEqual(lines.count("DUPLICATE seq=17"), 1)

    def test_reliability_client_finishes_when_all_ack_are_lost(self):
        # Сокет удерживает порт открытым, но не отвечает на PING или SHOOT.
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as silent:
            silent.bind(("127.0.0.1", 0))
            result = self.client(
                silent.getsockname()[1], count=1, extra=("--mode", "reliability", "--max-attempts", "2")
            )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("SHOOT not confirmed seq=0 attempts=2", result.stderr)
        with (self.root / "samples.csv").open() as file:
            rows = list(csv.DictReader(file, delimiter=";"))
        self.assertEqual([row["event"] for row in rows], ["sent", "retransmit", "failed", "final"])
        self.assertEqual([row["attempts"] for row in rows[:3]], ["1", "2", "2"])


if __name__ == "__main__":
    unittest.main(argv=["test_integration.py", *REST])
