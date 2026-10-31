"""Run all six real UDP series sequentially and record exact provenance."""
import argparse
from datetime import datetime, timedelta, timezone
import hashlib
import json
import os
from pathlib import Path
import platform
import socket
import subprocess
import sys
import time

PROFILES = ('baseline', 'delay_50', 'delay_100', 'jitter', 'loss_5', 'combined')
MOSCOW = timezone(timedelta(hours=3), 'Europe/Moscow')
FLAGS = subprocess.CREATE_NO_WINDOW if os.name == 'nt' else 0


def timestamp():
    return datetime.now(MOSCOW).isoformat(timespec='seconds')


def fingerprint(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--bin-dir', type=Path, required=True)
    parser.add_argument('--output-dir', type=Path, default=Path(__file__).resolve().parents[1]/'docs')
    parser.add_argument('--count', type=int, default=50)
    parser.add_argument('--interval-ms', type=int, default=500)
    parser.add_argument('--timeout-ms', type=int, default=1000)
    parser.add_argument('--grace-ms', type=int, default=1200)
    parser.add_argument('--seed', type=int, default=20261031)
    parser.add_argument('--port', type=int, default=27015)
    args = parser.parse_args()
    if not (50 <= args.count <= 60000 and 200 <= args.interval_ms <= 1000 and 1 <= args.timeout_ms <= 60000
            and 0 <= args.grace_ms <= 60000 and 1 <= args.seed <= 0xffffffff and 1 <= args.port <= 65535):
        parser.error('experiment parameters outside supported/assignment ranges')
    root = Path(__file__).resolve().parents[1]
    binaries = args.bin_dir.resolve()
    suffix = '.exe' if os.name == 'nt' else ''
    server, client = binaries/('server'+suffix), binaries/('client'+suffix)
    if not server.is_file() or not client.is_file():
        parser.error('build the client and server first')
    output = args.output_dir.resolve(); output.mkdir(parents=True, exist_ok=True)
    samples = output/'latency_samples.csv'; manifest_path = output/'experiment_manifest.json'
    if samples.exists() or manifest_path.exists():
        parser.error('output already contains an experiment; choose a fresh --output-dir')
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as probe:
        probe.bind(('127.0.0.1', args.port))
    logs = output/'experiment_logs'; logs.mkdir(exist_ok=True)
    sources = sorted(p for folder in ('include', 'src', 'tests', 'scripts') for p in (root/folder).rglob('*')
                     if p.is_file() and p.suffix in ('.cpp', '.hpp', '.py', '.txt', '.ps1'))
    sources += [root/'CMakeLists.txt']
    revision = subprocess.run(['git', 'rev-parse', 'HEAD'], cwd=root, capture_output=True, text=True)
    manifest = dict(started_at=timestamp(), completed=False, os=platform.platform(), architecture=platform.machine(),
                    python=sys.version, host='127.0.0.1', port=args.port, count=args.count, interval_ms=args.interval_ms,
                    timeout_ms=args.timeout_ms, grace_ms=args.grace_ms, seed=args.seed,
                    emulator='built-in queued PONG emulator v1; xorshift32; two draws per valid PING',
                    impairment_direction='server response only; drops are simulated PONG omissions',
                    git_head=revision.stdout.strip(), source_sha256={str(p.relative_to(root)):fingerprint(p) for p in sources},
                    executable_sha256={p.name:fingerprint(p) for p in (server,client)}, series=[])

    def save():
        manifest_path.write_text(json.dumps(manifest, indent=2, ensure_ascii=False)+'\n', encoding='utf-8')

    save()
    for profile in PROFILES:
        run_id = 'run_'+datetime.now(MOSCOW).strftime('%Y%m%dT%H%M%S')+'_'+profile
        duration = args.count*args.interval_ms+args.timeout_ms+args.grace_ms+3000
        server_cmd = [str(server),'--port',str(args.port),'--profile',profile,'--seed',str(args.seed),'--duration-ms',str(duration)]
        client_cmd = [str(client),'--port',str(args.port),'--experiment',profile,'--count',str(args.count),
                      '--interval-ms',str(args.interval_ms),'--timeout-ms',str(args.timeout_ms),'--grace-ms',str(args.grace_ms),
                      '--csv',str(samples),'--run-id',run_id]
        item = dict(profile=profile, run_id=run_id, started_at=timestamp(), server_command=server_cmd, client_command=client_cmd)
        server_log = logs/(profile+'_server.txt')
        print('START', profile, timestamp(), flush=True)
        with server_log.open('w', encoding='utf-8') as file:
            process = subprocess.Popen(server_cmd, stdout=file, stderr=subprocess.STDOUT, creationflags=FLAGS)
            try:
                deadline = time.monotonic()+5
                while 'READY ' not in server_log.read_text(encoding='utf-8'):
                    if process.poll() is not None or time.monotonic()>deadline:
                        raise RuntimeError('server failed to become ready: '+server_log.read_text())
                    time.sleep(.01)
                result = subprocess.run(client_cmd, capture_output=True, text=True, timeout=duration/1000+5, creationflags=FLAGS)
                (logs/(profile+'_client.txt')).write_text(result.stdout+result.stderr, encoding='utf-8')
                if result.returncode:
                    raise RuntimeError(result.stderr)
                item['summary'] = json.loads(next(line[8:] for line in result.stdout.splitlines() if line.startswith('SUMMARY ')))
                if item['summary']['sent'] != args.count or item['summary']['received']+item['summary']['timeouts'] != args.count:
                    raise RuntimeError('inconsistent final measurement counts')
            finally:
                # Child is owned by this runner. Stop only this process, never unrelated servers.
                process.terminate(); process.wait(timeout=5)
        item['finished_at'] = timestamp(); manifest['series'].append(item); save()
        print('DONE', profile, json.dumps(item['summary']), flush=True)
    manifest['completed'] = True; manifest['finished_at'] = timestamp(); save()
    print('WROTE', samples, flush=True)


if __name__ == '__main__':
    main()
