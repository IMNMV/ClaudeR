"""The HTTP server that runs inside the user's Python session.

Speaks the same wire protocol as the R addin, so the existing bridge needs no
new transport. POST {code, agent_id, want_plot} and get back
{success, output, plot, error}. GET returns a status object.

Execution goes through IPython's run_cell when a shell is present, so output,
display hooks and the IDE's plot pane behave exactly as if the user had typed
the code. Outside IPython it falls back to exec against a persistent namespace.
"""

from __future__ import annotations

import base64
import io
import json
import os
import secrets
import threading
import time
import traceback
from http.server import BaseHTTPRequestHandler, HTTPServer
from typing import Any, Dict, List, Optional

from .discovery import TOKEN_HEADER, remove_record, write_record

MAX_OUTPUT_CHARS = 100_000

# Frozen log markers, matching R so one log file holds both sides and the
# existing parsers keep working.
_LOG_HEADER = "# --- [%s] ---\n# Code executed by %s:\n%s\n\n"
_LOG_OUTPUT = "#> "


class _State:
    def __init__(self) -> None:
        self.httpd: Optional[HTTPServer] = None
        self.thread: Optional[threading.Thread] = None
        self.session_name: str = "default"
        self.port: Optional[int] = None
        self.token: Optional[str] = None
        self.require_token: bool = False
        self.plot_auto: bool = True
        self.log_path: Optional[str] = None
        self.print_to_console: bool = True
        self.execution_count: int = 0
        self.agents: List[str] = []
        self.namespace: Dict[str, Any] = {}
        # R is single threaded and serialises on its event loop. Python can be
        # re-entered from the server thread, so serialise here instead.
        self.exec_lock = threading.Lock()


STATE = _State()


def _shell():
    try:
        from IPython import get_ipython
        return get_ipython()
    except Exception:
        return None


def _log(code: str, agent: str) -> None:
    """Write the code entry. Called before execution, so a hang still leaves
    a record of what was running."""
    if not STATE.log_path:
        return
    try:
        with open(STATE.log_path, "a") as fh:
            fh.write(_LOG_HEADER % (time.strftime("%Y-%m-%d %H:%M:%S"), agent, code))
    except Exception:
        pass


def _log_output(output: str) -> None:
    """Append what the code printed, under the entry just written for it.
    The "#> " prefix marks these lines as output rather than code, which is
    what the R-side log parsers already skip."""
    if not STATE.log_path or not output.strip():
        return
    try:
        lines = output.rstrip("\n").split("\n")
        if len(lines) > 40:
            lines = lines[:40] + ["... %d more lines not logged" % (len(lines) - 40)]
        with open(STATE.log_path, "a") as fh:
            fh.write("".join(_LOG_OUTPUT + l + "\n" for l in lines) + "\n")
    except Exception:
        pass


class _Tee(io.TextIOBase):
    """Capture a copy while the user still sees their own output.

    This is the Python counterpart of sink(split = TRUE) on the R side.
    """

    def __init__(self, real):
        self.real = real
        self.buf = io.StringIO()

    def write(self, s):
        try:
            self.real.write(s)
        except Exception:
            pass
        return self.buf.write(s)

    def flush(self):
        try:
            self.real.flush()
        except Exception:
            pass


def _figure_png(fignum: Optional[int] = None) -> Optional[str]:
    """PNG of the figure the executed code produced.

    Rendering must go through Agg. An IDE backend may carry no raster
    renderer of its own, and then a plain savefig quietly produces a broken
    image rather than failing: measured against Positron's
    FigureCanvasPositron, savefig gave 2098 bytes with the title missing and
    labels clipped, where Agg gave 12504 correct ones. savefig(backend="agg")
    renders through Agg for this one call and leaves fig.canvas alone, so the
    figure still belongs to the IDE and still shows in its plot pane.

    Two things that look like fixes and are not. bbox_inches="tight" computes
    a degenerate box on a figure the IDE has not drawn yet, and
    canvas.draw() on such a canvas leaves it unrenderable. Rendering a
    pickled copy loses data outright: a four-bar chart came back as one bar
    on a default 0-to-1 axis.
    """
    try:
        import matplotlib.pyplot as plt
    except Exception:
        return None
    nums = plt.get_fignums()
    if not nums:
        return None
    target = fignum if fignum in nums else nums[-1]
    try:
        fig = plt.figure(target)
    except Exception:
        return None

    data = b""
    try:
        buf = io.BytesIO()
        fig.savefig(buf, format="png", backend="agg")
        data = buf.getvalue()
    except (TypeError, ValueError):
        # The backend keyword arrived in matplotlib 3.4. Older versions get
        # a plain savefig, which is correct wherever the canvas can raster.
        try:
            buf = io.BytesIO()
            fig.savefig(buf, format="png")
            data = buf.getvalue()
        except Exception:
            return None
    except Exception:
        return None

    # A rendered figure is never this small. Refuse rather than hand back a
    # blank picture that reads as a real result.
    if len(data) < 1000:
        return None
    return base64.b64encode(data).decode()


def _run(code: str, agent_id: Optional[str], want_plot: bool) -> Dict[str, Any]:
    import sys as _sys

    agent = agent_id or "agent"
    if agent not in STATE.agents:
        STATE.agents.append(agent)

    if STATE.print_to_console:
        try:
            print("\n### LLM [%s] executing the following code ###\n%s\n"
                  "### End of LLM code ###\n" % (agent, code))
        except Exception:
            pass

    _log(code, agent)

    with STATE.exec_lock:
        try:
            import matplotlib.pyplot as _plt
            before = set(_plt.get_fignums())
        except Exception:
            before = set()

        tee_out, tee_err = _Tee(_sys.stdout), _Tee(_sys.stderr)
        real_out, real_err = _sys.stdout, _sys.stderr
        _sys.stdout, _sys.stderr = tee_out, tee_err
        error = None
        try:
            sh = _shell()
            if sh is not None:
                res = sh.run_cell(code, store_history=False, silent=False)
                if getattr(res, "error_in_exec", None) is not None:
                    error = "".join(traceback.format_exception_only(
                        type(res.error_in_exec), res.error_in_exec)).strip()
                elif getattr(res, "error_before_exec", None) is not None:
                    error = str(res.error_before_exec)
            else:
                exec(compile(code, "<clauder>", "exec"), STATE.namespace)
        except Exception as e:
            error = "".join(traceback.format_exception_only(type(e), e)).strip()
        finally:
            _sys.stdout, _sys.stderr = real_out, real_err

        output = tee_out.buf.getvalue() + tee_err.buf.getvalue()
        if len(output) > MAX_OUTPUT_CHARS:
            output = output[:MAX_OUTPUT_CHARS] + "\n... output truncated"

        try:
            import matplotlib.pyplot as _plt
            after = set(_plt.get_fignums())
        except Exception:
            after = set()
        new_figs = after - before
        drew = bool(new_figs) or (bool(after) and bool(before) and want_plot)
        # The user may already have figures open, so identify ours rather than
        # assuming the highest number is the one this call drew.
        target_fig = max(new_figs) if new_figs else (max(after) if after else None)

    STATE.execution_count += 1
    resp: Dict[str, Any] = {"success": error is None, "output": output}
    _log_output(output if error is None else (output + "\n" + error).strip())
    if error is not None:
        resp["error"] = error

    if drew:
        # want_plot is the with_plot tool asking outright, and always wins.
        if want_plot or STATE.plot_auto:
            png = _figure_png(target_fig)
            if png:
                resp["plot"] = {"data": png, "mime_type": "image/png"}
        else:
            resp["plot_available"] = True
            resp["output"] = (resp["output"] + ("\n" if resp["output"] else "")
                              + "[a plot was drawn; ask for it with the plot tool]")
    return resp


class _Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *a):  # keep the user's console clean
        pass

    def _send(self, obj: Dict[str, Any], status: int = 200) -> None:
        body = json.dumps(obj).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _authorised(self) -> bool:
        # Only browsers set Origin, and the bridge never does, so this closes
        # the drive-by webpage vector at no compatibility cost.
        if self.headers.get("Origin"):
            self._send({"error": "Cross-origin requests are not allowed"}, 403)
            return False
        if STATE.require_token:
            if self.headers.get(TOKEN_HEADER) != STATE.token:
                self._send({"error": "Missing or invalid session token"}, 401)
                return False
        return True

    def do_GET(self):
        if not self._authorised():
            return
        self._send({
            "running": True,
            "language": "python",
            "session_name": STATE.session_name,
            "port": STATE.port,
            "execution_count": STATE.execution_count,
            "connected_agents": list(STATE.agents),
            "plot_auto": STATE.plot_auto,
            "log_to_file": bool(STATE.log_path),
            "log_file_path": STATE.log_path or "",
        })

    def do_POST(self):
        if not self._authorised():
            return
        try:
            n = int(self.headers.get("Content-Length") or 0)
            body = json.loads(self.rfile.read(n) or b"{}")
        except Exception:
            self._send({"error": "Invalid JSON in request body"}, 400)
            return
        code = body.get("code")
        if not isinstance(code, str):
            self._send({"success": False, "error": "No code supplied"}, 400)
            return
        try:
            self._send(_run(code, body.get("agent_id"),
                            bool(body.get("want_plot"))))
        except Exception as e:
            self._send({"success": False, "error": "clauder internal error: %s" % e}, 500)


def start(session_name: str = "default", port: int = 8790,
          require_token: bool = False, log_file: Optional[str] = None,
          plot_auto: bool = True, print_to_console: bool = True,
          quiet: bool = False) -> Dict[str, Any]:
    """Expose this Python session to MCP agents.

    Returns a dict describing the running server. Call stop() to shut it down.
    """
    requested_port = int(port)
    if STATE.httpd is not None:
        if not quiet:
            print("clauder: already running on port %s as '%s'."
                  % (STATE.port, STATE.session_name))
        return {"running": True, "port": STATE.port,
                "session_name": STATE.session_name}

    STATE.session_name = session_name
    STATE.require_token = require_token
    STATE.plot_auto = plot_auto
    STATE.print_to_console = print_to_console
    STATE.token = secrets.token_hex(32)
    STATE.execution_count = 0
    STATE.agents = []
    STATE.log_path = log_file if log_file is not None else os.path.join(
        home_dir_safe(), "clauder_python_log.py")

    # Walk forward to the next free port rather than failing. A second session,
    # or a server the OS has not finished releasing, should not stop you
    # starting; being told which port you got is enough.
    httpd = None
    first_error = None
    for candidate in range(int(port), int(port) + 20):
        try:
            httpd = HTTPServer(("127.0.0.1", candidate), _Handler)
            port = candidate
            break
        except OSError as e:
            if first_error is None:
                first_error = e
    if httpd is None:
        raise RuntimeError(
            "No free port in %d-%d (%s). Pass port= explicitly."
            % (int(port), int(port) + 19, first_error)
        ) from None

    STATE.httpd = httpd
    STATE.port = int(port)
    try:
        write_record(session_name, STATE.port, STATE.token,
                     plot_auto=plot_auto, tool_sets="all")
    except Exception:
        httpd.server_close()
        STATE.httpd = None
        STATE.port = None
        raise

    t = threading.Thread(target=httpd.serve_forever, daemon=True,
                         name="clauder-server")
    t.start()
    STATE.thread = t

    if not quiet:
        moved = " (requested port was busy)" if STATE.port != int(requested_port) else ""
        print("clauder: listening on http://127.0.0.1:%d as session '%s'%s.\n"
              "Agents can now reach this Python session. Call clauder.stop() "
              "to end it." % (STATE.port, session_name, moved))
    return {"running": True, "port": STATE.port, "session_name": session_name,
            "language": "python", "token_required": require_token}


def home_dir_safe() -> str:
    from .discovery import home_dir
    return home_dir()


def stop(quiet: bool = False) -> None:
    """Shut the server down and remove this session's discovery record."""
    if STATE.httpd is None:
        if not quiet:
            print("clauder: not running.")
        return
    try:
        STATE.httpd.shutdown()
    except Exception:
        pass
    try:
        STATE.httpd.server_close()
    except Exception:
        pass
    try:
        remove_record(STATE.session_name)
    except Exception:
        pass
    STATE.httpd = None
    STATE.thread = None
    STATE.port = None
    if not quiet:
        print("clauder: stopped.")


def status() -> Dict[str, Any]:
    return {
        "running": STATE.httpd is not None,
        "session_name": STATE.session_name,
        "port": STATE.port,
        "language": "python",
        "execution_count": STATE.execution_count,
        "connected_agents": list(STATE.agents),
        "plot_auto": STATE.plot_auto,
        "log_file": STATE.log_path,
        "token_required": STATE.require_token,
    }
