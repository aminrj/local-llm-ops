#!/usr/bin/env python3
"""GPU arbiter: hands the RTX 3090 to the assistant only when you are not using it.

Rules, in order (decide() below is the whole policy, and the tests cover it):

1. A hold (`llm desk [hours]`) keeps the GPU for you: the agent server is stopped
   and stays stopped until the hold expires or `llm agent` lifts it.
2. Your servers win. If anything answers on the desk ports (8081-8083), or a
   ComfyUI process runs, the GPU is yours ("desk"). Your `llm` commands already
   stop the agent server first (codeoff kills every llama-server); a ComfyUI
   start stops it here.
3. With no agent server running, VRAM use above the threshold means something
   else holds the card (a Windows app, a game, a notebook): "desk" as well.
4. The agent server starts only after the GPU has been free for QUIET_SECONDS
   (10 min), or ONDEMAND_QUIET_SECONDS (2 min) when the assistant has asked for
   it in the last 5 minutes. The quiet window is what keeps it from slipping
   into the gap of an `llm 38` model switch.
5. Optional night handover (off by default): at NIGHT_HOUR, if your desk server
   has logged nothing for NIGHT_IDLE_SECONDS, it runs `llm off` so night jobs
   can use the card. You restart your model in the morning.

HTTP on 127.0.0.1:8091 (Caddy exposes it as /arbiter/* over mutual TLS):
  GET  /status   {"state": "ready|starting|free|desk|held|error", "reason": ..., ...}
  POST /request  the assistant wants the model; shortens the quiet window
  POST /hold     body {"hours": 4}; same as `llm desk 4`
  POST /release  lift the hold; same as `llm agent`

Standard library only. Runs as a systemd user unit (agent/systemd/llm-arbiter.service).
"""
from __future__ import annotations

import dataclasses
import json
import os
import pathlib
import re
import signal
import subprocess
import sys
import threading
import time
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

HERE = pathlib.Path(__file__).resolve().parent


def env_int(name: str, default: int) -> int:
    try:
        return int(os.environ.get(name, default))
    except ValueError:
        return default


@dataclasses.dataclass
class Config:
    listen_port: int = env_int("ARBITER_PORT", 8091)
    desk_ports: tuple = tuple(int(p) for p in os.environ.get("DESK_PORTS", "8081,8082,8083").split(",") if p)
    agent_port: int = env_int("AGENT_PORT", 8090)
    quiet_seconds: int = env_int("QUIET_SECONDS", 600)
    ondemand_quiet_seconds: int = env_int("ONDEMAND_QUIET_SECONDS", 120)
    demand_window_seconds: int = env_int("DEMAND_WINDOW_SECONDS", 300)
    vram_busy_mib: int = env_int("VRAM_BUSY_MIB", 3000)
    start_timeout_seconds: int = env_int("START_TIMEOUT_SECONDS", 420)
    poll_seconds: int = env_int("POLL_SECONDS", 15)
    comfy_pattern: str = os.environ.get("COMFY_PATTERN", "comfyui")
    night_handover: bool = os.environ.get("NIGHT_HANDOVER", "0") == "1"
    night_hour: int = env_int("NIGHT_HOUR", 1)
    night_idle_seconds: int = env_int("NIGHT_IDLE_SECONDS", 7200)
    state_dir: pathlib.Path = pathlib.Path(os.environ.get("ARBITER_STATE_DIR",
                                                          os.path.expanduser("~/.local/state/llm-arbiter")))
    log_dir: pathlib.Path = pathlib.Path(os.environ.get("LLAMA_LOG_DIR", os.path.expanduser("~/.local/share/llama-logs")))

    @property
    def hold_file(self) -> pathlib.Path:
        return self.state_dir / "hold"


@dataclasses.dataclass
class Observed:
    now: float
    hold_until: float          # 0 when no hold
    desk_up: bool              # a desk server answers /health
    comfy: bool                # a ComfyUI process runs
    vram_used_mib: int         # -1 when nvidia-smi is unavailable
    agent_up: bool             # the agent's llama-server process exists
    agent_healthy: bool        # and answers /health
    desk_log_mtime: float      # newest desk log write (0 when none)
    hour: int                  # local hour, for the night handover


@dataclasses.dataclass
class Memory:
    last_desk_seen: float
    demand_at: float = 0.0
    agent_started_at: float = 0.0


@dataclasses.dataclass
class Decision:
    state: str
    reason: str
    action: str = "none"       # none | start | stop | night_off


def decide(o: Observed, m: Memory, c: Config) -> Decision:
    """The policy. Pure: mutates only `m` (the remembered timestamps)."""
    if o.hold_until > o.now:
        return Decision("held", f"held for you until {time.strftime('%H:%M', time.localtime(o.hold_until))}",
                        "stop" if o.agent_up else "none")

    if o.desk_up or o.comfy:
        m.last_desk_seen = o.now
        if (c.night_handover and o.desk_up and not o.comfy and o.hour == c.night_hour
                and o.desk_log_mtime and o.now - o.desk_log_mtime >= c.night_idle_seconds):
            return Decision("desk", "night handover: your idle desk server is stopped", "night_off")
        what = "ComfyUI is running" if o.comfy else "your model server is running"
        return Decision("desk", what, "stop" if o.agent_up else "none")

    if not o.agent_up and o.vram_used_mib > c.vram_busy_mib:
        m.last_desk_seen = o.now
        return Decision("desk", f"{o.vram_used_mib} MiB of VRAM in use by something else")

    if o.agent_up:
        if o.agent_healthy:
            return Decision("ready", "the assistant's model is loaded")
        if m.agent_started_at and o.now - m.agent_started_at > c.start_timeout_seconds:
            return Decision("error", "the assistant's model did not become healthy in time", "stop")
        return Decision("starting", "the assistant's model is loading")

    quiet = o.now - m.last_desk_seen
    wanted = m.demand_at and o.now - m.demand_at <= c.demand_window_seconds
    needed = c.ondemand_quiet_seconds if wanted else c.quiet_seconds
    if quiet >= needed:
        return Decision("starting", "the GPU has been free long enough", "start")
    return Decision("free", f"GPU free; the assistant may load it in {int(needed - quiet)} s")


# ---------- observation ----------

def http_ok(port: int, path: str = "/health", timeout: float = 2.0) -> bool:
    try:
        with urllib.request.urlopen(f"http://127.0.0.1:{port}{path}", timeout=timeout) as r:
            return 200 <= r.status < 300
    except Exception:
        return False


def proc_cmdlines() -> list[str]:
    out = []
    for p in pathlib.Path("/proc").iterdir():
        if not p.name.isdigit():
            continue
        try:
            out.append((p / "cmdline").read_bytes().replace(b"\0", b" ").decode(errors="replace"))
        except OSError:
            continue
    return out


def agent_pids(c: Config) -> list[int]:
    pat = re.compile(rf"llama-server\b.*--port {c.agent_port}\b")
    pids = []
    for p in pathlib.Path("/proc").iterdir():
        if not p.name.isdigit():
            continue
        try:
            cmd = (p / "cmdline").read_bytes().replace(b"\0", b" ").decode(errors="replace")
        except OSError:
            continue
        if pat.search(cmd):
            pids.append(int(p.name))
    return pids


def vram_used_mib() -> int:
    try:
        out = subprocess.run(["nvidia-smi", "--query-gpu=memory.used", "--format=csv,noheader,nounits", "-i", "0"],
                             capture_output=True, text=True, timeout=10, check=True).stdout.strip()
        return int(out.splitlines()[0])
    except Exception:
        return -1


def hold_until(c: Config) -> float:
    try:
        return float(c.hold_file.read_text().strip())
    except (OSError, ValueError):
        return 0.0


def desk_log_mtime(c: Config) -> float:
    newest = 0.0
    for name in ("codemode.log", "qwen38.log", "beellama.log", "codemode-mtp.log"):
        try:
            newest = max(newest, (c.log_dir / name).stat().st_mtime)
        except OSError:
            pass
    return newest


def observe(c: Config) -> Observed:
    now = time.time()
    pids = agent_pids(c)
    comfy_re = re.compile(c.comfy_pattern, re.I)
    return Observed(
        now=now,
        hold_until=hold_until(c),
        desk_up=any(http_ok(p) for p in c.desk_ports),
        comfy=any(comfy_re.search(cmd) for cmd in proc_cmdlines()),
        vram_used_mib=vram_used_mib(),
        agent_up=bool(pids),
        agent_healthy=bool(pids) and http_ok(c.agent_port),
        desk_log_mtime=desk_log_mtime(c),
        hour=time.localtime(now).tm_hour,
    )


# ---------- actions ----------

def start_agent(c: Config) -> None:
    log = open(c.state_dir / "run-agent.out", "ab")
    subprocess.Popen(["bash", str(HERE / "run-agent.sh")], stdout=log, stderr=subprocess.STDOUT,
                     stdin=subprocess.DEVNULL, start_new_session=True)


def stop_agent(c: Config) -> None:
    for pid in agent_pids(c):
        try:
            os.kill(pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
    for _ in range(15):
        if not agent_pids(c):
            return
        time.sleep(1)
    for pid in agent_pids(c):
        try:
            os.kill(pid, signal.SIGKILL)
        except ProcessLookupError:
            pass


def night_off() -> None:
    subprocess.run(["bash", str(HERE / "codeoff.sh")], capture_output=True, timeout=60)


# ---------- service ----------

class Arbiter:
    def __init__(self, c: Config):
        self.c = c
        self.m = Memory(last_desk_seen=time.time())   # conservative: a full quiet window after boot
        self.lock = threading.Lock()
        self.last: dict = {"state": "free", "reason": "starting up"}
        c.state_dir.mkdir(parents=True, exist_ok=True)

    def tick(self) -> dict:
        with self.lock:
            o = observe(self.c)
            d = decide(o, self.m, self.c)
            if d.action == "start":
                self.m.agent_started_at = o.now
                start_agent(self.c)
            elif d.action == "stop":
                stop_agent(self.c)
                self.m.agent_started_at = 0.0
            elif d.action == "night_off":
                night_off()
            changed = d.state != self.last.get("state")
            self.last = {"state": d.state, "reason": d.reason, "since": self.last.get("since") if not changed else o.now,
                         "vram_used_mib": o.vram_used_mib, "agent_up": o.agent_up}
            if changed:
                print(f"{time.strftime('%F %T')} {d.state}: {d.reason}" + (f" [{d.action}]" if d.action != "none" else ""),
                      flush=True)
            return self.last

    def request(self) -> dict:
        with self.lock:
            self.m.demand_at = time.time()
        return self.tick()

    def hold(self, hours: float) -> dict:
        self.c.hold_file.write_text(str(time.time() + hours * 3600))
        return self.tick()

    def release(self) -> dict:
        try:
            self.c.hold_file.unlink()
        except FileNotFoundError:
            pass
        with self.lock:
            self.m.demand_at = time.time()
            self.m.last_desk_seen = 0.0     # an explicit `llm agent`: start now if the GPU is free
        return self.tick()


def serve(a: Arbiter) -> None:
    class H(BaseHTTPRequestHandler):
        def _send(self, code: int, body: dict) -> None:
            data = json.dumps(body).encode()
            self.send_response(code)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)

        def do_GET(self):  # noqa: N802
            if self.path == "/status":
                with a.lock:
                    self._send(200, a.last)
            else:
                self._send(404, {"error": "not found"})

        def do_POST(self):  # noqa: N802
            length = int(self.headers.get("Content-Length") or 0)
            body = json.loads(self.rfile.read(length) or b"{}") if length else {}
            if self.path == "/request":
                self._send(200, a.request())
            elif self.path == "/hold":
                self._send(200, a.hold(float(body.get("hours", 4))))
            elif self.path == "/release":
                self._send(200, a.release())
            else:
                self._send(404, {"error": "not found"})

        def log_message(self, *args):  # quiet: the state changes are logged instead
            pass

    ThreadingHTTPServer(("127.0.0.1", a.c.listen_port), H).serve_forever()


def main() -> None:
    c = Config()
    a = Arbiter(c)
    threading.Thread(target=serve, args=(a,), daemon=True).start()
    print(f"llm-arbiter on 127.0.0.1:{c.listen_port}; desk ports {c.desk_ports}, agent :{c.agent_port}, "
          f"quiet {c.quiet_seconds}s, night handover {'on' if c.night_handover else 'off'}", flush=True)
    while True:
        try:
            a.tick()
        except Exception as e:  # keep serving; the next tick retries
            print(f"tick failed: {e}", file=sys.stderr, flush=True)
        time.sleep(c.poll_seconds)


if __name__ == "__main__":
    main()
