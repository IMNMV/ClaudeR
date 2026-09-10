"""Tests for the Python session server.

Each test runs against a private discovery directory, never the user's real
~/.claude_r_sessions, so a test run cannot disturb a live research session.
"""

import base64
import json
import os
import sys
import tempfile
import unittest
import urllib.error
import urllib.request

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "src"))

from clauder import server as srv          # noqa: E402
from clauder import discovery as disc      # noqa: E402

PORT = 8894


class Base(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.mkdtemp()
        self._real_home = disc.home_dir
        disc.home_dir = lambda: self.dir
        self.log = os.path.join(self.dir, "log.py")

    def tearDown(self):
        srv.stop(quiet=True)
        disc.home_dir = self._real_home

    def start(self, **kw):
        kw.setdefault("session_name", "t")
        kw.setdefault("port", PORT)
        kw.setdefault("quiet", True)
        kw.setdefault("print_to_console", False)
        kw.setdefault("log_file", self.log)
        return srv.start(**kw)

    def post(self, code, want_plot=False, token=None, origin=None, agent="tester"):
        body = {"code": code, "agent_id": agent}
        if want_plot:
            body["want_plot"] = True
        h = {"Content-Type": "application/json"}
        if token:
            h[disc.TOKEN_HEADER] = token
        if origin:
            h["Origin"] = origin
        r = urllib.request.Request("http://127.0.0.1:%d" % PORT,
                                   json.dumps(body).encode(), h)
        return json.load(urllib.request.urlopen(r, timeout=25))

    def record(self):
        with open(disc.discovery_path("t")) as fh:
            return json.load(fh)


class DiscoveryTests(Base):
    def test_record_declares_python_and_matches_r_shape(self):
        self.start()
        rec = self.record()
        # The bridge reads these keys for every session regardless of language.
        for k in ("session_name", "port", "pid", "token", "started_at",
                  "plot_auto", "tool_sets", "language"):
            self.assertIn(k, rec)
        self.assertEqual(rec["language"], "python")
        self.assertEqual(rec["port"], PORT)
        self.assertEqual(rec["pid"], os.getpid())

    def test_record_is_private(self):
        self.start()
        mode = os.stat(disc.discovery_path("t")).st_mode & 0o777
        self.assertEqual(mode, 0o600)

    def test_stop_removes_only_our_record(self):
        self.start()
        p = disc.discovery_path("t")
        self.assertTrue(os.path.exists(p))
        srv.stop(quiet=True)
        self.assertFalse(os.path.exists(p))

    def test_refuses_name_held_by_another_live_process(self):
        os.makedirs(disc.discovery_dir(), mode=0o700, exist_ok=True)
        with open(disc.discovery_path("t"), "w") as fh:
            json.dump({"session_name": "t", "port": 1, "pid": 1,
                       "token": "x", "started_at": "s"}, fh)
        with self.assertRaises(RuntimeError):
            self.start()

    def test_pid_probe_is_tristate(self):
        self.assertIs(disc.pid_is_alive(os.getpid()), True)
        self.assertIs(disc.pid_is_alive(999999), False)
        self.assertIsNone(disc.pid_is_alive("nonsense"))

    def test_rejects_unsafe_session_names(self):
        for bad in ("..", "a/b", "a\\b", "a:b", ""):
            with self.assertRaises(ValueError):
                disc.discovery_path(bad)


class ExecutionTests(Base):
    def test_executes_and_persists_namespace(self):
        self.start()
        self.assertTrue(self.post("zz = 6 * 7")["success"])
        r = self.post("print('zz is', zz)")
        self.assertIn("zz is 42", r["output"])

    def test_reports_errors_without_dying(self):
        self.start()
        r = self.post("1/0")
        self.assertFalse(r["success"])
        self.assertIn("ZeroDivisionError", r["error"])
        self.assertTrue(self.post("1+1")["success"])   # still serving

    def test_captures_stdout(self):
        self.start()
        r = self.post("for i in range(3): print('row', i)")
        self.assertIn("row 0", r["output"])
        self.assertIn("row 2", r["output"])

    def test_logs_code_and_output_with_attribution(self):
        self.start()
        self.post("print('logged')", agent="agent-7")
        text = open(self.log).read()
        self.assertIn("# Code executed by agent-7:", text)   # frozen R marker
        self.assertIn("#> logged", text)                     # output marker
        # The code must appear exactly once, not once per log call.
        self.assertEqual(text.count("print('logged')"), 1)

    def test_output_is_truncated(self):
        # Lower the cap rather than printing a huge string: the tee echoes to
        # the real console by design, and a 200k flood makes test output
        # unreadable.
        self.start()
        original = srv.MAX_OUTPUT_CHARS
        srv.MAX_OUTPUT_CHARS = 100
        try:
            r = self.post("print('x' * 500)")
            self.assertLessEqual(len(r["output"]), 100 + 40)
            self.assertIn("truncated", r["output"])
        finally:
            srv.MAX_OUTPUT_CHARS = original


class SecurityTests(Base):
    def test_origin_header_is_refused(self):
        self.start()
        with self.assertRaises(urllib.error.HTTPError) as e:
            self.post("1+1", origin="http://evil.test")
        self.assertEqual(e.exception.code, 403)

    def test_token_enforced_when_required(self):
        self.start(require_token=True)
        tok = self.record()["token"]
        with self.assertRaises(urllib.error.HTTPError) as e:
            self.post("1+1")
        self.assertEqual(e.exception.code, 401)
        self.assertTrue(self.post("1+1", token=tok)["success"])

    def test_token_absent_by_default(self):
        self.start()
        self.assertTrue(self.post("1+1")["success"])


class PlotTests(Base):
    def setUp(self):
        super().setUp()
        try:
            import matplotlib
            matplotlib.use("Agg")
        except ImportError:
            self.skipTest("matplotlib not installed")

    def draw(self, **kw):
        return self.post("import matplotlib.pyplot as plt\n"
                         "plt.figure(); plt.plot([1, 4, 9])", **kw)

    def test_returns_png_when_a_figure_is_drawn(self):
        self.start()
        r = self.draw()
        self.assertIn("plot", r)
        self.assertEqual(r["plot"]["mime_type"], "image/png")
        self.assertTrue(base64.b64decode(r["plot"]["data"]).startswith(b"\x89PNG"))

    def test_no_plot_when_nothing_drawn(self):
        self.start()
        self.assertNotIn("plot", self.post("q = 1"))

    def test_plot_auto_off_withholds_image_but_says_so(self):
        self.start(plot_auto=False)
        r = self.draw()
        self.assertNotIn("plot", r)
        self.assertTrue(r["plot_available"])
        self.assertIn("plot was drawn", r["output"])

    def test_want_plot_overrides_plot_auto(self):
        self.start(plot_auto=False)
        self.assertIn("plot", self.draw(want_plot=True))


class StatusTests(Base):
    def test_get_reports_language_and_agents(self):
        self.start()
        self.post("1+1", agent="agent-a")
        r = urllib.request.Request("http://127.0.0.1:%d" % PORT)
        r.get_method = lambda: "GET"
        info = json.load(urllib.request.urlopen(r, timeout=10))
        self.assertEqual(info["language"], "python")
        self.assertTrue(info["running"])
        self.assertIn("agent-a", info["connected_agents"])

    def test_status_helper(self):
        self.start()
        self.assertTrue(srv.status()["running"])
        srv.stop(quiet=True)
        self.assertFalse(srv.status()["running"])

    def test_double_start_is_a_no_op(self):
        a = self.start()
        b = self.start()
        self.assertEqual(a["port"], b["port"])

    def test_busy_port_moves_to_the_next_free_one(self):
        # Occupy the requested port from outside. Calling start() twice would
        # hit the already-running guard and never reach the bind.
        import socket
        sock = socket.socket()
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        sock.bind(("127.0.0.1", PORT + 1))
        sock.listen(1)
        try:
            info = srv.start(session_name="t", port=PORT + 1, quiet=True,
                             log_file=self.log)
            self.assertNotEqual(info["port"], PORT + 1)
            self.assertGreater(info["port"], PORT + 1)
            # The record must carry the port actually bound, not the one asked
            # for, or the bridge would post to the wrong place.
            self.assertEqual(self.record()["port"], info["port"])
        finally:
            sock.close()

    def test_gives_up_when_the_whole_range_is_busy(self):
        import socket
        base = PORT + 40
        socks = []
        try:
            for i in range(20):
                s_ = socket.socket()
                s_.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
                s_.bind(("127.0.0.1", base + i))
                s_.listen(1)
                socks.append(s_)
            with self.assertRaises(RuntimeError) as e:
                srv.start(session_name="t", port=base, quiet=True,
                          log_file=self.log)
            self.assertIn("No free port", str(e.exception))
        finally:
            for s_ in socks:
                s_.close()


if __name__ == "__main__":
    unittest.main(verbosity=2)
