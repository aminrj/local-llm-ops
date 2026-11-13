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


# ---------- auto-off ----------

CA = arbiter.Config(auto_off=True, auto_off_idle_seconds=1800, auto_off_retry_seconds=900)


def idle_mem(**kw):
    base = dict(last_desk_seen=NOW - 10_000, started_at=NOW - 10_000)
    base.update(kw)
    return arbiter.Memory(**base)


def test_auto_off_disabled_by_default():
    assert arbiter.decide_power(obs(), idle_mem(), C, "free")[0] is False


def test_auto_off_when_idle_long_enough():
    m = idle_mem()
    off, why = arbiter.decide_power(obs(agent_log_mtime=NOW - 1900), m, CA, "ready")
    assert off and "idle for 31 min" in why and m.off_sent_at == NOW


def test_recent_request_keeps_it_on():
    off, why = arbiter.decide_power(obs(agent_log_mtime=NOW - 600), idle_mem(), CA, "ready")
    assert not off and why.startswith("auto-off in 21 min")
    assert not arbiter.decide_power(obs(), idle_mem(demand_at=NOW - 60), CA, "free")[0]


def test_full_window_after_boot():
    assert not arbiter.decide_power(obs(), idle_mem(started_at=NOW - 300), CA, "free")[0]


def test_people_keep_it_on_and_restart_the_window():
    for o, word in ((obs(windows_users=1), "signed in"), (obs(windows_users=-1), "unreadable"),
                    (obs(ssh_sessions=2), "SSH"), (obs(stayon_until=NOW + 60), "stayon")):
        m = idle_mem()
        off, why = arbiter.decide_power(o, m, CA, "free")
        assert not off and word in why and m.last_present == NOW
    # they left 5 minutes ago: the idle window counts from then
    assert not arbiter.decide_power(obs(), idle_mem(last_present=NOW - 300), CA, "free")[0]


def test_gpu_in_use_keeps_it_on():
    for state in ("desk", "held", "starting"):
        assert not arbiter.decide_power(obs(), idle_mem(), CA, state)[0]
    assert arbiter.decide_power(obs(), idle_mem(), CA, "error")[0]   # a broken model doesn't keep it on


def test_shutdown_sent_once_then_retried_after_cancel():
    m = idle_mem()
    assert arbiter.decide_power(obs(), m, CA, "free")[0]
    assert arbiter.decide_power(obs(now=NOW + 60), m, CA, "free") == (False, "shutdown sent")
    assert arbiter.decide_power(obs(now=NOW + 901), m, CA, "free")[0]


def test_ssh_sessions_reads_established_on_port():
    import tempfile
    tmp_path = pathlib.Path(tempfile.mkdtemp())
    head = "  sl  local_address rem_address   st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode\n"
    (tmp_path / "tcp").write_text(head +
        "   0: 00000000:08AE 00000000:0000 0A 00000000:00000000 00:00000000 00000000  0 0 1\n"   # listening
        "   1: 0B6A6A64:08AE 378E7A64:E0B8 01 00000000:00000000 00:00000000 00000000  0 0 2\n"   # established
        "   2: 0B6A6A64:1F90 378E7A64:E0B9 01 00000000:00000000 00:00000000 00000000  0 0 3\n")  # other port
    assert arbiter.ssh_sessions(2222, tmp_path) == 1


if __name__ == "__main__":
    for name, fn in list(globals().items()):
        if name.startswith("test_"):
            fn()
    print("ok")


# ---------- 2026-11-13: `llm code` while the agent was loaded froze the PC ----------
# codeoff killed the agent, the arbiter restarted it in the gap before the 35B
# answered /health, and both models loaded onto the 24 GB card at once.

def test_loading_desk_server_counts_as_desk():
    m = mem()
    d = arbiter.decide(obs(desk_proc=True), m, C)
    assert (d.state, d.action) == ("desk", "none") and m.last_desk_seen == NOW
    d = arbiter.decide(obs(desk_proc=True, agent_up=True, agent_healthy=True), mem(), C)
    assert (d.state, d.action) == ("desk", "stop")


def test_agent_killed_by_codeoff_restarts_quiet_window():
    m = mem()
    assert arbiter.decide(obs(agent_up=True, agent_healthy=True), m, C).state == "ready"
    # next tick: codeoff killed it, the desk server has not started yet
    d = arbiter.decide(obs(now=NOW + 15), m, C)
    assert (d.state, d.action) == ("free", "none") and m.last_desk_seen == NOW + 15


def test_agent_stopped_by_arbiter_does_not_count_as_desk():
    m = mem()
    arbiter.decide(obs(agent_up=True, agent_healthy=True), m, C)
    m.agent_stopping = True               # what tick() sets before stop_agent()
    d = arbiter.decide(obs(now=NOW + 15), m, C)
    assert d.action == "start" and not m.agent_stopping


def test_loaded_agent_missing_health_check_is_not_killed():
    m = mem(agent_started_at=NOW - 30)
    assert arbiter.decide(obs(agent_up=True, agent_healthy=True), m, C).state == "ready"
    d = arbiter.decide(obs(now=NOW + 900, agent_up=True, agent_healthy=False), m, C)
    assert d.action == "none"


def test_failed_load_backs_off_a_quiet_window():
    m = mem(agent_started_at=NOW - 500)
    assert arbiter.decide(obs(agent_up=True), m, C).action == "stop"
    m.agent_stopping = True
    assert arbiter.decide(obs(now=NOW + 15), m, C).action == "none"
    assert arbiter.decide(obs(now=NOW + 601), m, C).action == "start"
