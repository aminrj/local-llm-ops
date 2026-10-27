"""Policy tests for scripts/arbiter.py: python3 -m pytest tests/ (or python3 tests/test_arbiter.py)."""
import importlib.util
import pathlib
import sys

spec = importlib.util.spec_from_file_location("arbiter", pathlib.Path(__file__).resolve().parents[1] / "scripts/arbiter.py")
arbiter = importlib.util.module_from_spec(spec)
sys.modules["arbiter"] = arbiter
spec.loader.exec_module(arbiter)

C = arbiter.Config(quiet_seconds=600, ondemand_quiet_seconds=120, demand_window_seconds=300,
                   vram_busy_mib=3000, start_timeout_seconds=420, night_handover=False)
NOW = 1_000_000.0


def obs(**kw):
    base = dict(now=NOW, hold_until=0, desk_up=False, comfy=False, vram_used_mib=600, agent_up=False,
                agent_healthy=False, desk_log_mtime=0, hour=14)
    base.update(kw)
    return arbiter.Observed(**base)


def mem(**kw):
    base = dict(last_desk_seen=NOW - 10_000)
    base.update(kw)
    return arbiter.Memory(**base)


def test_hold_stops_agent():
    d = arbiter.decide(obs(hold_until=NOW + 60, agent_up=True, agent_healthy=True), mem(), C)
    assert (d.state, d.action) == ("held", "stop")


def test_desk_server_wins_and_stops_agent():
    d = arbiter.decide(obs(desk_up=True, agent_up=True), mem(), C)
    assert (d.state, d.action) == ("desk", "stop")


def test_comfy_counts_as_desk():
    m = mem()
    d = arbiter.decide(obs(comfy=True), m, C)
    assert d.state == "desk" and m.last_desk_seen == NOW


def test_foreign_vram_counts_as_desk_only_without_agent():
    assert arbiter.decide(obs(vram_used_mib=9000), mem(), C).state == "desk"
    assert arbiter.decide(obs(vram_used_mib=22000, agent_up=True, agent_healthy=True), mem(), C).state == "ready"


def test_quiet_window_blocks_start_after_model_switch():
    # codeoff just ran (desk seen 5 s ago): the agent must not slip into the gap
    d = arbiter.decide(obs(), mem(last_desk_seen=NOW - 5), C)
    assert (d.state, d.action) == ("free", "none")


def test_start_after_quiet_window():
    d = arbiter.decide(obs(), mem(last_desk_seen=NOW - 601), C)
    assert (d.state, d.action) == ("starting", "start")


def test_demand_shortens_window():
    m = mem(last_desk_seen=NOW - 130, demand_at=NOW - 10)
    assert arbiter.decide(obs(), m, C).action == "start"
    m = mem(last_desk_seen=NOW - 130, demand_at=NOW - 1000)   # stale demand
    assert arbiter.decide(obs(), m, C).action == "none"


def test_start_timeout_stops():
    d = arbiter.decide(obs(agent_up=True, agent_healthy=False), mem(agent_started_at=NOW - 500), C)
    assert (d.state, d.action) == ("error", "stop")


def test_night_handover_only_when_enabled_and_idle():
    m = mem()
    o = obs(desk_up=True, hour=1, desk_log_mtime=NOW - 8000)
    assert arbiter.decide(o, m, C).action == "none"
    c = arbiter.Config(night_handover=True, night_hour=1, night_idle_seconds=7200)
    assert arbiter.decide(o, m, c).action == "night_off"
    assert arbiter.decide(obs(desk_up=True, hour=1, desk_log_mtime=NOW - 60), m, c).action == "none"


if __name__ == "__main__":
    for name, fn in list(globals().items()):
        if name.startswith("test_"):
            fn()
    print("ok")
