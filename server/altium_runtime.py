"""Shared runtime of the bridge to Altium: one script executor, many callers.

Altium runs one DelphiScript at a time, and every MCP server process (one per
Claude session) talks to the same Altium through files in EXCHANGE_DIR. This
module holds what keeps those callers from stepping on each other:

- altium_lock: a cross-process, re-entrant lock held for the whole life of a
  script run (commands, sandbox runs, probes, recovery);
- an in-flight marker, so a call that was cancelled or timed out is settled
  by the next call instead of being run over;
- request/response files named by a request id, written and read so that a
  half-written file or a late answer to an earlier request is never taken
  for the current one;
- a reading of Altium's state (script debugger paused, busy, waiting on a
  dialog) and a dialog allowlist: only acknowledgement boxes are closed, a
  question about a design document is never answered on the user's behalf.
"""
import asyncio
import contextlib
import contextvars
import json
import os
import re
import subprocess
import time
import uuid
from pathlib import Path
from typing import Optional

EXCHANGE_DIR = Path("C:/Users/Public/altium_mcp")
REQUEST_FILE = EXCHANGE_DIR / "request.json"
LOCK_FILE = EXCHANGE_DIR / "bridge.lock"
INFLIGHT_FILE = EXCHANGE_DIR / "inflight.json"

# Seconds to wait for an answer; anything not listed gets the default
DEFAULT_COMMAND_TIMEOUT = 120
COMMAND_TIMEOUTS = {
    "build_circuit": 300,
    "create_footprints_batch": 300,
    "create_symbols_batch": 300,
    "get_erc_violations": 300,
    "get_project_components": 300,
    "get_schematic_data": 300,
    "run_output_jobs": 600,
    # waits for the user to drag a rectangle around the destination parts
    "layout_duplicator": 300,
    "layout_duplicator_apply": 300,
}

# Seconds Altium may stay responsive without answering before a script is
# taken to have died; commands that wait for the user are exempt
IDLE_EXIT = 12
NO_IDLE_EXIT = {"layout_duplicator"}

# Button captions of Altium's message boxes, '&' accelerators removed
_BUTTON_LABELS = {"OK", "Yes", "No", "Cancel", "Abort", "Retry", "Ignore", "Yes to All",
                  "No to All", "All", "Close", "Help", "Continue", "Try Again"}
DIALOG_CLASSES = ("#32770", "TMessageForm", "TForm_RunScriptParameters")


def command_timeout(command: str) -> int:
    return COMMAND_TIMEOUTS.get(command, DEFAULT_COMMAND_TIMEOUT)


def new_request_id() -> str:
    return uuid.uuid4().hex[:12]


# --- lock --------------------------------------------------------------------

_lock_held = contextvars.ContextVar("altium_lock_held", default=False)
_local_lock: Optional[asyncio.Lock] = None


def _try_lock(f) -> bool:
    import msvcrt
    try:
        f.seek(0)
        msvcrt.locking(f.fileno(), msvcrt.LK_NBLCK, 1)
        return True
    except OSError:
        return False


def _unlock(f) -> None:
    import msvcrt
    try:
        f.seek(0)
        msvcrt.locking(f.fileno(), msvcrt.LK_UNLCK, 1)
    except OSError:
        pass


@contextlib.asynccontextmanager
async def altium_lock(timeout: float):
    """Exclusive use of Altium's script executor; yields False on timeout.

    An OS byte-range lock, so it works across MCP server processes and a
    crashed holder never leaves it stuck. Re-entrant within one call: a
    command that recovers the executor runs a probe under the same lock.
    """
    global _local_lock
    if _lock_held.get():
        yield True
        return
    if _local_lock is None:
        _local_lock = asyncio.Lock()
    deadline = time.time() + timeout
    try:
        await asyncio.wait_for(_local_lock.acquire(), max(timeout, 0.1))
    except asyncio.TimeoutError:
        yield False
        return
    f = None
    try:
        EXCHANGE_DIR.mkdir(exist_ok=True)
        f = open(LOCK_FILE, "a+b")
        got = _try_lock(f)
        while not got and time.time() < deadline:
            await asyncio.sleep(0.5)
            got = _try_lock(f)
        if not got:
            yield False
            return
        token = _lock_held.set(True)
        try:
            yield True
        finally:
            _lock_held.reset(token)
            _unlock(f)
    finally:
        if f is not None:
            f.close()
        _local_lock.release()


# --- in-flight marker ----------------------------------------------------------

def set_inflight(kind: str, run_id: str, what: str, done_file: Path, extra=None) -> None:
    """Record the run now handed to Altium; cleared once it is settled."""
    data = {"kind": kind, "id": run_id, "what": what, "done_file": str(done_file),
            "started": time.time(), "pid": os.getpid()}
    data.update(extra or {})
    INFLIGHT_FILE.write_text(json.dumps(data), encoding="utf-8")


def read_inflight() -> Optional[dict]:
    try:
        return json.loads(INFLIGHT_FILE.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return None


def clear_inflight() -> None:
    try:
        INFLIGHT_FILE.unlink()
    except OSError:
        pass


# --- request / response files ------------------------------------------------

def response_file(request_id: str) -> Path:
    return EXCHANGE_DIR / f"response_{request_id}.json"


def write_request(command: str, params: dict, request_id: str) -> None:
    """Write request.json atomically.

    The Pascal side reads it line by line: json.dump(indent=2) puts every
    top-level key on its own line with two spaces of indent and every array
    element on its own line. ASCII only (non-ASCII as \\uXXXX), which the
    script decodes, so the file reads the same under any ANSI code page.
    """
    data = {"request_id": request_id, "command": command, **params}
    tmp = REQUEST_FILE.with_name(f"request_{request_id}.tmp")
    with open(tmp, "w", encoding="ascii") as f:
        json.dump(data, f, indent=2, ensure_ascii=True)
    os.replace(tmp, REQUEST_FILE)


async def read_json_file(path: Path, read_text, attempts: int = 10) -> dict:
    """Parse a JSON file Altium may still be writing; retries a partial read."""
    last = None
    for _ in range(attempts):
        try:
            return json.loads(read_text(path))
        except (OSError, ValueError) as e:
            last = e
            await asyncio.sleep(0.3)
    raise last


def remove_stale_files(max_age: float = 3600) -> None:
    """Old per-run answers and logs nobody will read any more."""
    now = time.time()
    for pattern in ("response_*.json", "request_*.tmp", "sandbox_result_*.json",
                    "sandbox_log_*.txt", "sandbox_go_*"):
        for p in EXCHANGE_DIR.glob(pattern):
            try:
                if now - p.stat().st_mtime > max_age:
                    p.unlink()
            except OSError:
                pass


def unlink(*paths) -> None:
    for p in paths:
        try:
            Path(p).unlink()
        except OSError:
            pass


# --- sandbox source ----------------------------------------------------------

SANDBOX_BEGIN = "// === BEGIN EXPERIMENT"
SANDBOX_END = "// === END EXPERIMENT"
SANDBOX_RUN_ID_RE = re.compile(r"^(\s*SBX_RUN_ID\s*=\s*)'[^']*'(\s*;)", re.MULTILINE)


def sandbox_source(template: str, body: str, run_id: str) -> str:
    """The sandbox unit with the experiment body and run id put in.

    Built from the pristine template every time, so a body that happens to
    contain the END marker, or a half-written earlier run, cannot corrupt
    later runs.
    """
    pre, rest = template.split(SANDBOX_BEGIN, 1)
    marker_line, rest = rest.split("\n", 1)
    _, post = rest.split(SANDBOX_END, 1)
    pre, n = SANDBOX_RUN_ID_RE.subn(lambda m: f"{m.group(1)}'{run_id}'{m.group(2)}", pre)
    if n != 1:
        raise ValueError("sandbox template has no SBX_RUN_ID constant")
    return pre + SANDBOX_BEGIN + marker_line + "\n" + body + "\n        " + SANDBOX_END + post


def ascii_pascal(code: str) -> str:
    """The script with every non-ASCII character made ASCII.

    Altium reads a .pas file in the ANSI code page whatever its byte-order
    mark, so 'µ' arrived as 'Вµ'. Inside string literals a character becomes
    a character code (#181, #937 ...), which the script engine decodes to the
    real Unicode character; anywhere else (comments) it becomes '?'.
    """
    out, i, in_str, n = [], 0, False, len(code)
    while i < n:
        c = code[i]
        if in_str:
            if c == "'":
                if i + 1 < n and code[i + 1] == "'":
                    out.append("''")
                    i += 2
                    continue
                in_str = False
                out.append(c)
            elif ord(c) > 127:
                out.append(f"'+#{ord(c)}+'")
            else:
                out.append(c)
        else:
            if c == "'":
                in_str = True
            out.append(c if ord(c) < 128 else "?")
        i += 1
    return "".join(out)


def sandbox_files(run_id: str):
    """(log, result, start marker) of a sandbox run; a probe run has no id."""
    if not run_id:
        return (EXCHANGE_DIR / "sandbox_log.txt", EXCHANGE_DIR / "sandbox_result.json", None)
    return (EXCHANGE_DIR / f"sandbox_log_{run_id}.txt",
            EXCHANGE_DIR / f"sandbox_result_{run_id}.json",
            EXCHANGE_DIR / f"sandbox_go_{run_id}")


# --- dialogs and Altium state ------------------------------------------------

def classify_dialog(cls: str, title: str, buttons, script_in_front: bool) -> bool:
    """True when a dialog may be closed without asking the user.

    Closable: a box whose only button is OK (an error or notice that just
    needs acknowledging - "another instance is busy", a script runtime
    error), and "Select Item To Run". A question (Yes/No, OK/Cancel ...)
    is answered by the user, except while a script project is in front:
    then it is about the script files the server itself rewrites.
    """
    if cls == "TForm_RunScriptParameters":
        return True
    labels = {b.replace("&", "").strip() for b in buttons} & _BUTTON_LABELS
    if labels == {"OK"}:
        return True
    if script_in_front and cls == "TMessageForm" and title in ("Confirm", "Warning") and labels:
        return True
    return False


def _win32():
    import ctypes
    from ctypes import wintypes
    return ctypes, wintypes, ctypes.windll.user32, ctypes.windll.kernel32


def _process_name(hwnd) -> str:
    ctypes, wintypes, user32, kernel32 = _win32()
    pid = wintypes.DWORD()
    user32.GetWindowThreadProcessId(hwnd, ctypes.byref(pid))
    handle = kernel32.OpenProcess(0x1000, False, pid.value)  # PROCESS_QUERY_LIMITED_INFORMATION
    if not handle:
        return ""
    try:
        buf = ctypes.create_unicode_buffer(1024)
        size = wintypes.DWORD(len(buf))
        if kernel32.QueryFullProcessImageNameW(handle, 0, buf, ctypes.byref(size)):
            return os.path.basename(buf.value)
        return ""
    finally:
        kernel32.CloseHandle(handle)


def _text(hwnd) -> str:
    ctypes, _, user32, _ = _win32()
    n = user32.GetWindowTextLengthW(hwnd)
    buf = ctypes.create_unicode_buffer(n + 1)
    user32.GetWindowTextW(hwnd, buf, n + 1)
    return buf.value


def _class(hwnd) -> str:
    ctypes, _, user32, _ = _win32()
    buf = ctypes.create_unicode_buffer(128)
    user32.GetClassNameW(hwnd, buf, 128)
    return buf.value


def _altium_windows():
    """Visible top-level windows of X2.EXE: (hwnd, class, title)."""
    try:
        ctypes, wintypes, user32, _ = _win32()
    except (ImportError, AttributeError, OSError):
        return []
    found = []

    @ctypes.WINFUNCTYPE(wintypes.BOOL, wintypes.HWND, wintypes.LPARAM)
    def cb(hwnd, lparam):
        if user32.IsWindowVisible(hwnd) and _process_name(hwnd).lower() == "x2.exe":
            found.append((hwnd, _class(hwnd), _text(hwnd)))
        return True

    user32.EnumWindows(cb, 0)
    return found


def _child_texts(hwnd):
    ctypes, wintypes, user32, _ = _win32()
    texts = []

    @ctypes.WINFUNCTYPE(wintypes.BOOL, wintypes.HWND, wintypes.LPARAM)
    def cb(child, lparam):
        t = _text(child)
        if t:
            texts.append(t)
        return True

    user32.EnumChildWindows(hwnd, cb, 0)
    return texts


def scan_dialogs():
    """Altium's open message boxes with their buttons and whether each may be
    closed (see classify_dialog)."""
    windows = _altium_windows()
    script_in_front = any(".PrjScr" in t and "Altium Designer" in t for _, _, t in windows)
    dialogs = []
    for hwnd, cls, title in windows:
        if cls not in DIALOG_CLASSES:
            continue
        if cls == "TMessageForm" and title not in ("Error", "Warning", "Information", "Confirm"):
            continue
        children = _child_texts(hwnd)
        buttons = [t for t in children if t.replace("&", "").strip() in _BUTTON_LABELS]
        message = " ".join(t for t in children if t not in buttons)[:300]
        dialogs.append({
            "hwnd": hwnd, "class": cls, "title": title,
            "buttons": [b.replace("&", "") for b in buttons], "message": message,
            "busy_instance": "busy" in message.lower(),
            "closable": classify_dialog(cls, title, buttons, script_in_front)})
    return dialogs


def close_dialogs():
    """Close the closable dialogs; returns (closed, left open) dialog lists."""
    try:
        _, _, user32, _ = _win32()
    except (ImportError, AttributeError, OSError):
        return [], []
    closed, waiting = [], []
    for d in scan_dialogs():
        if d["closable"]:
            user32.PostMessageW(d["hwnd"], 0x0010, 0, 0)  # WM_CLOSE
            closed.append(d)
        else:
            waiting.append(d)
    return closed, waiting


def describe_dialogs(dialogs) -> str:
    return "; ".join(f"'{d['title']}' [{'/'.join(d['buttons']) or '?'}]"
                     + (f": {d['message']}" if d.get("message") else "") for d in dialogs)


def altium_hung() -> bool:
    """True while Altium's main window does not process messages: a script
    (or a long operation of the user's) is running."""
    try:
        _, _, user32, _ = _win32()
    except (ImportError, AttributeError, OSError):
        return False
    return any(user32.IsHungAppWindow(h) for h, c, t in _altium_windows()
               if "Altium Designer" in t and c not in DIALOG_CLASSES)


def altium_state() -> dict:
    """What Altium is doing right now, as far as can be seen from outside.

    hung: the main window does not process messages - a script (or the
    user's own operation) is still running.
    debugger_paused: an Error box is up, which is how a script runtime error
    shows. A pause without a box is not visible from outside (the window
    title keeps naming the script project even after the debugger is
    stopped), so callers treat "idle without an answer" as a possible pause
    and run the recovery, which is harmless when nothing is paused.
    """
    try:
        _, _, user32, _ = _win32()
    except (ImportError, AttributeError, OSError):
        return {"running": False, "hung": False, "debugger_paused": False, "dialogs": []}
    windows = _altium_windows()
    mains = [h for h, c, t in windows if "Altium Designer" in t and c not in DIALOG_CLASSES]
    dialogs = scan_dialogs()
    return {"running": bool(mains),
            "hung": any(user32.IsHungAppWindow(h) for h in mains),
            "debugger_paused": any(d["title"] == "Error" for d in dialogs),
            "dialogs": dialogs}


def launch(cmd: str) -> None:
    subprocess.Popen(cmd, shell=True)


async def launch_and_wait(cmd: str, done_file: Path, timeout: float, settle: float = 3,
                          idle_exit: Optional[float] = IDLE_EXIT,
                          progress_file: Optional[Path] = None) -> dict:
    """Start a RunScript command line and wait for done_file.

    Altium refuses a RunScript while it is busy ("There is another instance
    ... busy", an OK box from the launcher): the script was not taken, so
    the box is closed and the launch repeated. Other closable boxes are
    closed as they come; questions are left for the user and reported.

    A running script keeps Altium's window from processing messages (it is
    "hung"). When Altium stays responsive for idle_exit seconds without an
    answer, and progress_file (the script's own log) does not grow, the
    script is not running any more - it died or stopped in the debugger -
    and waiting longer only burns the caller's time.
    """
    start = time.time()
    launch(cmd)
    launches = 1
    closed, waiting = {}, {}
    idle_since = None
    last_progress = None
    idle = False
    while time.time() - start < timeout:
        await asyncio.sleep(0.5)
        if done_file.exists():
            break
        if time.time() - start < settle:
            continue
        now_closed, now_waiting = close_dialogs()
        for d in now_closed:
            closed[d["hwnd"]] = d
        if now_closed:
            idle_since = None  # Altium carries on once its box is closed
        waiting = {d["hwnd"]: d for d in now_waiting}
        if any(d["busy_instance"] for d in now_closed) and not done_file.exists():
            await asyncio.sleep(2)
            launch(cmd)
            launches += 1
            idle_since = None
            continue
        if idle_exit is None or waiting:
            continue
        progress = None
        if progress_file is not None:
            try:
                progress = progress_file.stat().st_mtime
            except OSError:
                pass
        if altium_hung() or progress != last_progress:
            idle_since = None
        elif idle_since is None:
            idle_since = time.time()
        elif time.time() - idle_since >= idle_exit:
            idle = not done_file.exists()
            break
        last_progress = progress
    return {"done": done_file.exists(), "elapsed": round(time.time() - start, 1),
            "launches": launches, "idle": idle,
            "closed": list(closed.values()), "waiting": list(waiting.values())}
