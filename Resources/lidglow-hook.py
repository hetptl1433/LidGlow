#!/usr/bin/python3
"""Local-only LidGlow activity bridge. No agent content is persisted or emitted."""

import contextlib
import fcntl
import hashlib
import json
import os
from pathlib import Path
import select
import stat
import sys
import time

SOURCES = ("claude", "codex", "custom")
STATES = ("working", "attention", "complete", "idle", "error")
MARKER = "--lidglow-hook"
MAX_INPUT = 1024 * 1024
MAX_EVENTS = 256
MAX_AGE = 24 * 60 * 60
MAX_CONFIG = 8 * 1024 * 1024
REPEAT_INTERVAL = 30
UNSET = object()
EVENTS = {
    "codex": {
        "UserPromptSubmit": "working",
        "PreToolUse": "working",
        "PostToolUse": "working",
        "PermissionRequest": "attention",
        "Stop": "complete",
        "Interrupt": "idle",
        "SessionEnd": "idle",
    },
    "claude": {
        "UserPromptSubmit": "working",
        "PreToolUse": "working",
        "PostToolUse": "working",
        "PermissionRequest": "attention",
        "Notification": "attention",
        "Stop": "complete",
        "StopFailure": "error",
        "SessionEnd": "idle",
    },
}


def home_dir():
    return Path(os.environ.get("LIDGLOW_HOME", str(Path.home()))).absolute()


def data_dir():
    value = os.environ.get("LIDGLOW_DATA_DIR")
    return Path(value).absolute() if value else home_dir() / "Library/Application Support/LidGlow"


def no_symlinks(path):
    """Reject existing symlinks in this path, including directory components."""
    path = Path(path).absolute()
    for item in [*reversed(path.parents), path]:
        if item.is_symlink():
            raise ValueError("LidGlow will not read or write through a symbolic link.")
    return path


def ensure_dir(path):
    no_symlinks(path)
    path.mkdir(parents=True, exist_ok=True, mode=0o700)
    no_symlinks(path)
    if not path.is_dir():
        raise ValueError("Expected a directory.")


def read_regular(path, limit=MAX_CONFIG):
    no_symlinks(path)
    flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0) | getattr(os, "O_NONBLOCK", 0)
    fd = os.open(path, flags)
    try:
        info = os.fstat(fd)
        if not stat.S_ISREG(info.st_mode):
            raise ValueError("Expected a regular file.")
        if info.st_nlink != 1:
            raise ValueError("Hard-linked files are not supported; no settings were changed.")
        if info.st_size > limit:
            raise ValueError("File exceeds the supported size limit; no settings were changed.")
        with os.fdopen(fd, "rb", closefd=False) as handle:
            content = handle.read(limit + 1)
            if len(content) > limit:
                raise ValueError("File exceeds the supported size limit; no settings were changed.")
            return content
    finally:
        os.close(fd)


def atomic_bytes(path, content, mode=0o600, expected=UNSET):
    no_symlinks(path)
    ensure_dir(path.parent)
    if path.exists():
        existing = path.lstat()
        if not stat.S_ISREG(existing.st_mode) or existing.st_nlink != 1:
            raise ValueError("Expected a regular destination file without hard links.")
    # O_EXCL creates a private temporary file without loading tempfile's large
    # import tree for every tool event. Randomness comes from the operating system.
    tmp = path.parent / (".lidglow-" + os.urandom(12).hex())
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0), mode)
    try:
        os.fchmod(fd, mode)
        with os.fdopen(fd, "wb") as handle:
            handle.write(content)
            handle.flush()
            os.fsync(handle.fileno())
        no_symlinks(path)
        if expected is not UNSET:
            current = read_regular(path) if path.exists() else None
            if current != expected:
                raise ValueError("Agent settings changed during this update. Please try again.")
        os.replace(tmp, path)
    finally:
        if os.path.exists(tmp):
            os.unlink(tmp)


def acquire_lock(fd, timeout):
    deadline = time.monotonic() + timeout
    while True:
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            return
        except BlockingIOError:
            if time.monotonic() >= deadline:
                raise TimeoutError("Another LidGlow update is still running. Please try again.")
            time.sleep(0.005)


@contextlib.contextmanager
def event_lock(directory):
    path = directory / ".lidglow.lock"
    no_symlinks(path)
    fd = os.open(path, os.O_CREAT | os.O_RDWR | getattr(os, "O_NOFOLLOW", 0) | getattr(os, "O_NONBLOCK", 0), 0o600)
    try:
        info = os.fstat(fd)
        if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1:
            raise ValueError("Expected a regular lock file.")
        acquire_lock(fd, 0.25)
        yield
    finally:
        os.close(fd)


def prune_events(directory, now, keep=None):
    files = []
    for entry in directory.iterdir():
        if entry == keep:
            continue
        if entry.suffix != ".json" or entry.is_symlink():
            continue
        try:
            info = entry.lstat()
            if not stat.S_ISREG(info.st_mode):
                continue
            if now - info.st_mtime > MAX_AGE:
                entry.unlink(missing_ok=True)
            else:
                files.append((info.st_mtime, entry))
        except OSError:
            pass
    # Snapshot count is bounded even with many short-lived sessions.
    limit = MAX_EVENTS - (1 if keep is not None else 0)
    for _, path in sorted(files)[: max(0, len(files) - limit)]:
        try:
            path.unlink(missing_ok=True)
        except OSError:
            pass


def emit(source, state, session, preserve_finish=False):
    if source not in SOURCES or state not in STATES:
        return
    if not isinstance(session, str) or not session or len(session) > 4096:
        return
    session_hash = hashlib.sha256(session.encode("utf-8")).hexdigest()[:24]
    now = time.time()
    snapshot = {"source": source, "session_id": session_hash, "state": state, "timestamp": now}
    directory = data_dir() / "events"
    ensure_dir(directory)
    destination = directory / (source + "-" + session_hash + ".json")
    with event_lock(directory):
        # Serialize writers so an older process cannot overwrite a newer event.
        # Coalesce unchanged working states to avoid disk writes and
        # waking the menu-bar app for every PreToolUse/PostToolUse pair.
        try:
            previous = strict_json(read_regular(destination, limit=4096))
        except (OSError, ValueError):
            previous = None
        if isinstance(previous, dict) and previous.get("source") == source and previous.get("session_id") == session_hash:
            old_time = previous.get("timestamp")
            if isinstance(old_time, (float, int)) and not isinstance(old_time, bool):
                if (preserve_finish and state == "idle" and previous.get("state") in ("complete", "error")
                        and old_time > 0 and old_time <= now + 60 and now - old_time < MAX_AGE):
                    return
                if now < old_time <= now + 60:
                    return
                if state == "working" and previous.get("state") == state and 0 <= now - old_time < REPEAT_INTERVAL:
                    return
        atomic_bytes(destination, json.dumps(snapshot, separators=(",", ":"), allow_nan=False).encode("utf-8"))
        prune_events(directory, now, keep=destination)


def config_path(agent):
    if agent == "claude":
        return home_dir() / ".claude/settings.json"
    return home_dir() / ".codex/hooks.json"


def read_config(path):
    no_symlinks(path)
    if not path.exists():
        return {}, None
    raw = read_regular(path)
    try:
        config = strict_json(raw)
    except (ValueError, UnicodeError) as error:
        raise ValueError("Existing agent settings contain invalid JSON; no settings were changed.") from error
    if not isinstance(config, dict):
        raise ValueError("Existing agent settings must be a JSON object; no settings were changed.")
    if "hooks" in config and not isinstance(config["hooks"], dict):
        raise ValueError("Existing hooks must be a JSON object; no settings were changed.")
    # Do not guess at an unexpected schema and risk discarding user settings.
    for groups in config.get("hooks", {}).values():
        if not isinstance(groups, list):
            raise ValueError("Existing hook groups have an unsupported shape; no settings were changed.")
        for group in groups:
            if not isinstance(group, dict) or not isinstance(group.get("hooks"), list):
                raise ValueError("Existing hook groups have an unsupported shape; no settings were changed.")
            if "matcher" in group and not isinstance(group["matcher"], str):
                raise ValueError("Existing hook matchers must be strings; no settings were changed.")
            if not all(isinstance(handler, dict) for handler in group["hooks"]):
                raise ValueError("Existing hook handlers have an unsupported shape; no settings were changed.")
    return config, raw


def owned(handler):
    import shlex
    command = handler.get("command")
    if handler.get("type") != "command" or not isinstance(command, str):
        return False
    try:
        parts = shlex.split(command)
    except ValueError:
        return False
    # Require our marker and the actual managed executable/interpreter position.
    # Merely mentioning a path in somebody else's command is not ownership.
    if MARKER not in parts:
        return False
    native = str(data_dir() / "lidglow-signal")
    python = str(data_dir() / "lidglow-hook.py")
    return bool(parts) and (parts[0] == native or
                           (len(parts) > 1 and parts[0] == "/usr/bin/python3" and parts[1] == python))


def remove_owned(config):
    removed = False
    hooks = config.get("hooks", {})
    for event in list(hooks):
        kept = []
        event_removed = False
        for group in hooks[event]:
            handlers = [handler for handler in group["hooks"] if not owned(handler)]
            if len(handlers) != len(group["hooks"]):
                removed = True
                event_removed = True
                if handlers:
                    updated = dict(group)
                    updated["hooks"] = handlers
                    kept.append(updated)
            else:
                kept.append(group)
        if kept or not event_removed:
            hooks[event] = kept
        else:
            del hooks[event]
    # Keep an explicit empty hooks object/list if it belonged to the user.
    return removed


def has_owned(config):
    return any(owned(handler) for groups in config.get("hooks", {}).values()
               for group in groups for handler in group["hooks"])


@contextlib.contextmanager
def config_lock(path):
    ensure_dir(path.parent)
    lock_path = path.parent / ".lidglow.lock"
    no_symlinks(lock_path)
    flags = os.O_CREAT | os.O_RDWR | getattr(os, "O_NOFOLLOW", 0) | getattr(os, "O_NONBLOCK", 0)
    fd = os.open(lock_path, flags, 0o600)
    try:
        info = os.fstat(fd)
        if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1:
            raise ValueError("Expected a regular lock file.")
        acquire_lock(fd, 0.75)
        yield
    finally:
        os.close(fd)


def save_config(path, config, previous):
    # Fail if another app changed settings while we prepared this update.
    current = read_regular(path) if path.exists() else None
    if current != previous:
        raise ValueError("Agent settings changed during this update. Please try again.")
    if previous is not None:
        stamp = time.strftime("%Y%m%d-%H%M%S")
        backup = path.with_name(path.name + ".lidglow-backup-" + stamp + "-" + os.urandom(3).hex())
        atomic_bytes(backup, previous)
    atomic_bytes(path, (json.dumps(config, indent=2, ensure_ascii=False, allow_nan=False) + "\n").encode("utf-8"), expected=previous)


def hook_groups(agent, native=False):
    import shlex
    helper = data_dir() / "lidglow-hook.py"
    # Use macOS's installed system Python. The app checks that it is available.
    prefix = shlex.quote(str(data_dir() / "lidglow-signal")) if native else "/usr/bin/python3 " + shlex.quote(str(helper))
    result = {}
    for event, state in EVENTS[agent].items():
        command = prefix + " event --source " + agent + " --state " + state + " " + MARKER
        if event == "SessionEnd":
            command += " --preserve-finish"
        group = {"hooks": [{"type": "command", "command": command, "timeout": 2}]}
        if event == "Notification":
            group["matcher"] = "permission_prompt|idle_prompt"
        result[event] = [group]
    return result


def installation_status(config, agent):
    import shlex
    if not has_owned(config):
        return False, "Hooks not installed."
    native_path = str(data_dir() / "lidglow-signal")
    native = any(owned(handler) and shlex.split(handler["command"])[0] == native_path
                 for groups in config.get("hooks", {}).values() for group in groups for handler in group["hooks"])
    helper = data_dir() / ("lidglow-signal" if native else "lidglow-hook.py")
    try:
        if not read_regular(helper, limit=32 * MAX_INPUT):
            raise ValueError("Empty helper file.")
        if native and not os.access(helper, os.X_OK):
            raise ValueError("Native helper is not executable.")
    except (OSError, ValueError):
        return False, "The LidGlow helper is missing or unreadable. Choose Install hooks to repair the integration."
    actual = config.get("hooks", {})
    for event, expected_groups in hook_groups(agent, native=native).items():
        expected_group = expected_groups[0]
        expected_handler = expected_group["hooks"][0]
        expected_command = shlex.split(expected_handler["command"])
        complete = False
        for group in actual.get(event, []):
            matcher = group.get("matcher", "")
            if event == "Notification":
                if matcher != expected_group["matcher"]:
                    continue
            elif matcher not in ("", "*"):
                continue
            for handler in group["hooks"]:
                if not owned(handler):
                    continue
                if shlex.split(handler["command"]) == expected_command:
                    complete = True
                    break
            if complete:
                break
        if not complete:
            return False, "LidGlow's hook configuration is incomplete. Choose Install hooks to repair the integration."
    message = "Hooks installed."
    if agent == "codex":
        message += " Trust is not checked here; review the hooks in Codex Settings > Hooks or /hooks."
    return True, message


def manage(action, agent, native_helper=None):
    path = config_path(agent)
    if action == "status":
        config, _ = read_config(path)
        installed, message = installation_status(config, agent)
        return {"ok": True, "installed": installed, "message": message}
    with config_lock(path):
        config, raw = read_config(path)
        before = json.dumps(config, sort_keys=True, allow_nan=False)
        removed = remove_owned(config)
        if action == "install":
            native_content = None
            if native_helper is not None:
                native_content = read_regular(Path(native_helper).absolute(), limit=32 * MAX_INPUT)
                # A copied script would make production depend on an interpreter.
                # Accept only a native Mach-O executable or universal binary.
                if native_content[:4] not in (b"\xcf\xfa\xed\xfe", b"\xce\xfa\xed\xfe", b"\xfe\xed\xfa\xcf", b"\xfe\xed\xfa\xce", b"\xca\xfe\xba\xbe", b"\xbe\xba\xfe\xca", b"\xca\xfe\xba\xbf", b"\xbf\xba\xfe\xca"):
                    raise ValueError("The bundled signal helper is not a native macOS executable.")
            helper = data_dir() / "lidglow-hook.py"
            source = Path(__file__).absolute()
            content = read_regular(source)
            atomic_bytes(helper, content, mode=0o700)
            if native_content is not None:
                atomic_bytes(data_dir() / "lidglow-signal", native_content, mode=0o700)
            hooks = config.setdefault("hooks", {})
            for event, groups in hook_groups(agent, native=native_content is not None).items():
                hooks.setdefault(event, []).extend(groups)
            if json.dumps(config, sort_keys=True, allow_nan=False) != before:
                save_config(path, config, raw)
            message = "Hooks installed. "
            message += ("In Codex, open Settings > Hooks or /hooks and review and trust LidGlow's hooks."
                        if agent == "codex" else "Restart Claude Code or review /hooks to load them.")
            return {"ok": True, "installed": True, "message": message}
        if removed:
            save_config(path, config, raw)
        return {"ok": True, "installed": False,
                "message": "LidGlow hooks removed. Other hooks and settings were preserved."}


def parser():
    import argparse
    root = argparse.ArgumentParser(description="LidGlow local activity bridge")
    commands = root.add_subparsers(dest="command", required=True)
    for name in ("install", "uninstall", "status"):
        sub = commands.add_parser(name)
        sub.add_argument("--agent", choices=("claude", "codex"), required=True)
        if name == "install":
            sub.add_argument("--native-helper", help="Bundled LidGlowSignal native executable")
    for name in ("event", "emit"):
        sub = commands.add_parser(name)
        sub.add_argument("--source", choices=SOURCES, required=True)
        sub.add_argument("--state", choices=STATES, required=True)
        sub.add_argument(MARKER, action="store_true", help=argparse.SUPPRESS)
        sub.add_argument("--preserve-finish", action="store_true",
                         help="An idle event keeps a recent completion or error signal")
        if name == "emit":
            sub.add_argument("--session", default="default")
    return root


def strict_json(content):
    import math
    def pairs(values):
        result = {}
        for key, value in values:
            if key in result:
                raise ValueError("Duplicate JSON keys are not supported.")
            result[key] = value
        return result
    def constant(_):
        raise ValueError("Non-finite JSON numbers are not supported.")
    def finite_float(value):
        number = float(value)
        if not math.isfinite(number):
            raise ValueError("JSON number exceeds the supported finite range.")
        return number
    return json.loads(content, object_pairs_hook=pairs, parse_constant=constant, parse_float=finite_float)


def read_hook_input():
    # A broken producer must not leave a hook process waiting for EOF forever.
    deadline = time.monotonic() + 0.5
    content = bytearray()
    while len(content) <= MAX_INPUT:
        remaining = deadline - time.monotonic()
        if remaining <= 0 or not select.select([sys.stdin.fileno()], [], [], remaining)[0]:
            return None
        chunk = os.read(sys.stdin.fileno(), min(65536, MAX_INPUT + 1 - len(content)))
        if not chunk:
            return bytes(content)
        content.extend(chunk)
    return None


def event_arguments(arguments):
    command = arguments[0]
    values = {"--session": "default"} if command == "emit" else {}
    index = 1
    while index < len(arguments):
        option = arguments[index]
        if option == MARKER:
            index += 1
            continue
        if option == "--preserve-finish":
            values[option] = True
            index += 1
            continue
        if "=" in option:
            option, value = option.split("=", 1)
            index += 1
        else:
            if index + 1 >= len(arguments):
                return None
            value = arguments[index + 1]
            index += 2
        if option not in ("--source", "--state", "--session") or (option == "--session" and command != "emit"):
            return None
        values[option] = value
    if values.get("--source") not in SOURCES or values.get("--state") not in STATES:
        return None
    return values


def main():
    arguments = sys.argv[1:]
    if arguments and arguments[0] in ("event", "emit") and not any(value in ("--help", "-h") for value in arguments):
        try:
            values = event_arguments(arguments)
            if values is None:
                return 0
            if arguments[0] == "event":
                raw = read_hook_input()
                if raw is None:
                    return 0
                value = strict_json(raw)
                if not isinstance(value, dict):
                    return 0
                session = value.get("session_id")
            else:
                session = values["--session"]
            emit(values["--source"], values["--state"], session, preserve_finish=values.get("--preserve-finish", False))
        except Exception:
            # Never print content or interfere with an agent because a status light failed.
            pass
        return 0
    args = parser().parse_args()
    try:
        result = manage(args.command, args.agent, getattr(args, "native_helper", None))
    except Exception as error:
        result = {"ok": False, "installed": False, "message": str(error)}
    print(json.dumps(result, allow_nan=False))
    return 0 if result["ok"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
