"""Linux Codex recap backend, sent through Herdr's remote exec as python3 -c."""

import datetime as dt
import fcntl
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile

LANGUAGE = "zh-TW"
UUID = re.compile(r"^[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}$")
ROOT = Path(os.environ.get("CODEX_HOME") or Path.home() / ".codex")
SESSIONS = ROOT / "sessions"
CACHE = Path(os.environ.get("XDG_CACHE_HOME") or Path.home() / ".cache") / "herdr-recap-codex"
PROMPT = (
    "Stop: this is a question about this session, not a continuation of its work. "
    "Do not run commands or use tools. 用繁體中文在 80 字內摘要：正在處理什麼、目前進度、下一步。只輸出摘要。"
)


def process(pid):
    raw = Path(f"/proc/{pid}/stat").read_text()
    ticks = int(raw.rsplit(") ", 1)[1].split()[19])
    boot = next(int(line.split()[1]) for line in Path("/proc/stat").read_text().splitlines() if line.startswith("btime "))
    started = boot + ticks / os.sysconf("SC_CLK_TCK")
    argv = Path(f"/proc/{pid}/cmdline").read_bytes().decode(errors="replace").strip("\0").split("\0")
    if not argv or "codex" not in Path(argv[0]).name.lower() or any(x in argv for x in ("app-server", "exec-server")):
        raise ValueError("Foreground process is not a Codex CLI conversation")
    cwd = os.readlink(f"/proc/{pid}/cwd")
    raw_env = Path(f"/proc/{pid}/environ").read_bytes().split(b"\0")
    path_entry = next((item[5:].decode(errors="replace") for item in raw_env if item.startswith(b"PATH=")), os.environ.get("PATH", ""))
    executable = shutil.which(argv[0], path=path_entry) or os.readlink(f"/proc/{pid}/exe")
    return started, argv, cwd, executable, ticks, path_entry


def session_files(session_id=None, started=None):
    if not SESSIONS.is_dir():
        raise ValueError("Codex sessions directory was not found on this machine")
    if session_id:
        return SESSIONS.rglob(f"rollout-*-{session_id}.jsonl")
    day = dt.datetime.fromtimestamp(started, dt.timezone.utc).date()
    folders = [SESSIONS / f"{(day + dt.timedelta(days=offset)):%Y/%m/%d}" for offset in (-1, 0, 1)]
    return (file for folder in folders for file in folder.glob("rollout-*.jsonl"))


def resolve_session(pid):
    started, argv, cwd, executable, ticks, _ = process(pid)
    mapped = CACHE / "processes" / f"{pid}.json"
    try:
        known = json.loads(mapped.read_text())
        file = Path(known["file"])
        if known["ticks"] == ticks and UUID.fullmatch(known["id"]) and file.is_file() and file.is_relative_to(SESSIONS):
            return {"id": known["id"], "file": file, "executable": executable}
    except (OSError, ValueError, KeyError, TypeError):
        pass
    resumed = next((argv[i + 1] for i, arg in enumerate(argv[:-1]) if arg == "resume" and UUID.fullmatch(argv[i + 1])), None)
    requested_cwd = next((argv[i + 1] for i, arg in enumerate(argv[:-1]) if arg == "-C"), cwd)
    found = []
    for file in session_files(resumed, started):
        try:
            with file.open() as stream:
                meta = json.loads(stream.readline())
            payload = meta["payload"]
            session_id = payload["session_id"]
            if meta["type"] != "session_meta" or payload.get("originator") != "codex-tui" or not UUID.fullmatch(session_id):
                continue
            if resumed and session_id != resumed:
                continue
            if not resumed:
                timestamp = dt.datetime.fromisoformat(payload["timestamp"].replace("Z", "+00:00")).timestamp()
                if not -2 <= timestamp - started <= 15 or payload.get("cwd") != requested_cwd:
                    continue
            found.append({"id": session_id, "file": file, "executable": executable})
        except (OSError, ValueError, KeyError, TypeError):
            continue
    if len(found) != 1:
        raise ValueError(f"Cannot identify one Codex session for process {pid}; found {len(found)}")
    mapped.parent.mkdir(parents=True, exist_ok=True)
    mapped.write_text(json.dumps({"id": found[0]["id"], "file": str(found[0]["file"]), "ticks": ticks}))
    return found[0]


def session_by_id(session_id):
    if not UUID.fullmatch(session_id):
        raise ValueError("Invalid session ID")
    files = list(session_files(session_id))
    if len(files) != 1:
        raise ValueError("Session transcript is missing or ambiguous")
    return {"id": session_id, "file": files[0]}


def cache_state(session):
    file = session["file"]
    stat = file.stat()
    try:
        saved = json.loads((CACHE / "recaps" / f"{session['id']}.json").read_text())
    except (OSError, ValueError):
        saved = {}
    error_file = CACHE / "recaps" / f"{session['id']}.error"
    try:
        error = error_file.read_text()
    except OSError:
        error = ""
    return {
        "session": session["id"],
        "recap": saved.get("recap", ""),
        "fresh": saved.get("language") == LANGUAGE and saved.get("size") == stat.st_size and saved.get("mtime_ns") == stat.st_mtime_ns,
        "at": saved.get("at", ""),
        "error": error,
    }


def inspect(requests):
    results = []
    for item in requests:
        pid = int(item["pid"])
        try:
            results.append({"pid": pid, **cache_state(resolve_session(pid))})
        except (OSError, ValueError, KeyError, TypeError) as exc:
            results.append({"pid": pid, "error": str(exc)})
    return results


def write_recap(session_id, pid):
    recap_dir = CACHE / "recaps"
    recap_dir.mkdir(parents=True, exist_ok=True)
    error_file = recap_dir / f"{session_id}.error"
    try:
        with (recap_dir / f"{session_id}.lock").open("w") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            error_file.unlink(missing_ok=True)
            session = session_by_id(session_id)
            if cache_state(session)["fresh"]:
                return
            _, _, _, executable, _, path_entry = process(pid)
            stat = session["file"].stat()
            with tempfile.TemporaryDirectory(prefix="herdr-recap-codex-") as temporary:
                output = Path(temporary) / "recap.txt"
                env = {key: value for key, value in os.environ.items() if not key.startswith("HERDR_")}
                env["PATH"] = path_entry
                command = [executable, "exec", "fork", session_id, "--ephemeral", "--skip-git-repo-check", "-c", 'sandbox_mode="read-only"', "-o", str(output), PROMPT]
                with (Path(temporary) / "codex.log").open("w") as log:
                    result = subprocess.run(command, cwd=temporary, env=env, stdin=subprocess.DEVNULL, stdout=log, stderr=log)
                if result.returncode:
                    raise ValueError(f"Codex exited with code {result.returncode}")
                recap = output.read_text().strip()
                if not recap or re.search(r"<tool_call>|<\|tool_call|<function_calls>|<invoke", recap):
                    raise ValueError("Codex returned an invalid recap")
            data = {"session": session_id, "language": LANGUAGE, "size": stat.st_size, "mtime_ns": stat.st_mtime_ns,
                    "recap": recap, "at": dt.datetime.now(dt.timezone.utc).isoformat()}
            temporary_cache = recap_dir / f"{session_id}.tmp"
            temporary_cache.write_text(json.dumps(data, ensure_ascii=False))
            temporary_cache.replace(recap_dir / f"{session_id}.json")
            error_file.unlink(missing_ok=True)
    except Exception as exc:
        error_file.write_text(str(exc))


def main():
    import sys
    action = sys.argv[1]
    if action == "inspect":
        print(json.dumps(inspect(json.loads(sys.argv[2])), ensure_ascii=False))
    elif action == "start":
        pid = int(sys.argv[2])
        session = resolve_session(pid)
        if cache_state(session)["fresh"]:
            print('{"status":"cached"}')
            return
        error_file = CACHE / "recaps" / f"{session['id']}.error"
        error_file.unlink(missing_ok=True)
        print(json.dumps({"status": "ready", "session": session["id"]}))
    elif action == "write":
        write_recap(sys.argv[2], int(sys.argv[3]))
    else:
        raise ValueError("Unknown action")


if __name__ == "__main__":
    main()
