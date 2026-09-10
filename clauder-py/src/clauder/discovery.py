"""Discovery records, byte-compatible with the R side.

Both languages write into ~/.claude_r_sessions so one bridge can see every
session regardless of which one it is. The record shape, the lock protocol and
the atomic replace all match R/ui.R deliberately. The only addition is the
`language` field, which is absent in records written by R before this existed
and therefore means "r" when missing.
"""

from __future__ import annotations

import json
import os
import re
import sys
import tempfile
import time
from typing import Any, Dict, Optional

# Frozen shared contract. Do not rename these.
DISCOVERY_DIRNAME = ".claude_r_sessions"
TOKEN_HEADER = "X-Clauder-Token"

_BAD_NAME = re.compile(r'[\\/:<>"|?*\x00-\x1f]')


def home_dir() -> str:
    if sys.platform == "win32":
        return os.environ.get("USERPROFILE") or os.path.expanduser("~")
    return os.path.expanduser("~")


def discovery_dir() -> str:
    return os.path.join(home_dir(), DISCOVERY_DIRNAME)


def discovery_path(session_name: str) -> str:
    if (not session_name or session_name in (".", "..")
            or _BAD_NAME.search(session_name)):
        raise ValueError("Invalid discovery session name")
    return os.path.join(discovery_dir(), session_name + ".json")


def pid_is_alive(pid: Any) -> Optional[bool]:
    """True, False, or None for "cannot tell".

    None matters. A permission error must not be read as permission to delete
    another session's record, which is why this is tri-state like the R side.
    """
    try:
        pid = int(pid)
    except (TypeError, ValueError):
        return None
    if pid <= 0:
        return None
    if sys.platform == "win32":
        try:
            import ctypes
            SYNCHRONIZE = 0x00100000
            h = ctypes.windll.kernel32.OpenProcess(SYNCHRONIZE, False, pid)
            if h:
                ctypes.windll.kernel32.CloseHandle(h)
                return True
            return False if ctypes.windll.kernel32.GetLastError() == 87 else None
        except Exception:
            return None
    try:
        os.kill(pid, 0)
        return True
    except ProcessLookupError:
        return False
    except PermissionError:
        return True          # alive, owned by someone else
    except Exception:
        return None


class _Lock:
    """Directory lock, the same mechanism R uses, so the two interoperate."""

    def __init__(self, path: str):
        self.lock = path + ".lock"

    def __enter__(self):
        try:
            os.mkdir(self.lock, 0o700)
        except FileExistsError:
            raise RuntimeError(
                "Discovery record is locked; do not remove another writer's lock"
            ) from None
        return self

    def __exit__(self, *exc):
        try:
            os.rmdir(self.lock)
        except OSError:
            pass
        return False


def write_record(session_name: str, port: int, token: str,
                 plot_auto: bool = True, tool_sets: Any = "all") -> str:
    d = discovery_dir()
    os.makedirs(d, mode=0o700, exist_ok=True)
    f = discovery_path(session_name)
    with _Lock(f):
        other = None
        if os.path.exists(f):
            try:
                with open(f) as fh:
                    other = json.load(fh)
            except Exception as e:
                raise RuntimeError(
                    "Unreadable discovery record at %s (%s). Inspect or remove "
                    "it, then start the server again." % (f, e)
                ) from None
        if other is not None and not isinstance(other, dict):
            raise RuntimeError(
                "Unreadable discovery identity in %s; explicit inspection required" % f)
        if other is not None and int(other.get("pid", -1)) != os.getpid() \
                and pid_is_alive(other.get("pid")) is not False:
            raise RuntimeError(
                "Session name '%s' is already owned by a live or unknown process"
                % session_name)

        same_owner = (other is not None
                      and int(other.get("pid", -1)) == os.getpid()
                      and other.get("token") == token)
        started = (other.get("started_at") if same_owner and other.get("started_at")
                   else time.strftime("%Y-%m-%dT%H:%M:%S"))

        info: Dict[str, Any] = {
            "session_name": session_name,
            "port": int(port),
            "pid": os.getpid(),
            "token": token,
            "started_at": started,
            "plot_auto": bool(plot_auto),
            "tool_sets": tool_sets,
            "language": "python",
        }
        fd, tmp = tempfile.mkstemp(prefix=".discovery-", dir=d)
        try:
            with os.fdopen(fd, "w") as fh:
                json.dump(info, fh, indent=2)
            os.chmod(tmp, 0o600)
            os.replace(tmp, f)      # atomic, including on Windows
        finally:
            if os.path.exists(tmp):
                os.unlink(tmp)
    return f


def remove_record(session_name: str) -> None:
    """Delete our own record only. Never another process's."""
    f = discovery_path(session_name)
    if not os.path.exists(f):
        return
    with _Lock(f):
        try:
            with open(f) as fh:
                info = json.load(fh)
        except Exception:
            return
        if isinstance(info, dict) and int(info.get("pid", -1)) == os.getpid():
            os.unlink(f)
