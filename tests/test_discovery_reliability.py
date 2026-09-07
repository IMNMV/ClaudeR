import asyncio
import importlib.util
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('tested_clauder_bridge', ROOT / 'clauder-mcp/src/clauder_mcp/server.py')
bridge = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bridge)


class DiscoveryTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.patch = mock.patch.object(bridge, 'SESSIONS_DIR', str(self.root))
        self.patch.start()
        self.addCleanup(self.patch.stop)
        bridge._target_session = None
        bridge._target_identity = None
        bridge._target_token = None
        bridge._agent_introduced = True

    def record(self, name='A', **kwargs):
        doc = dict(session_name=name, port=48878, pid=os.getpid(), started_at='start1', token='test-token')
        doc.update(kwargs)
        (self.root / (name + '.json')).write_text(json.dumps(doc), encoding='utf-8')
        return doc

    def test_corrupt_and_invalid_records_retained(self):
        for i, value in enumerate(('{', '[]', '{}', '{"pid":true}')):
            (self.root / f'{i}.json').write_text(value)
        self.assertEqual(bridge.discover_sessions(), [])
        self.assertEqual(len(list(self.root.glob('*.json'))), 4)

    def test_dead_record_not_deleted_by_bridge(self):
        self.record()
        with mock.patch.object(bridge, '_pid_alive', return_value=False):
            self.assertEqual(bridge.discover_sessions(), [])
        self.assertTrue((self.root / 'A.json').exists())

    def test_unknown_process_retained(self):
        self.record()
        with mock.patch.object(bridge, '_pid_alive', return_value=None):
            self.assertEqual(len(bridge.discover_sessions()), 1)

    @unittest.skipIf(os.name == 'nt', 'POSIX probe test; Windows uses WinAPI')
    def test_permission_failure_is_unknown(self):
        with mock.patch.object(bridge.os, 'kill', side_effect=PermissionError()):
            self.assertIsNone(bridge._pid_alive(123))

    def test_lost_target_does_not_switch(self):
        self.record()
        self.assertIn('48878', bridge.get_r_addin_url())
        (self.root / 'A.json').unlink()
        self.record('B', port=48879)
        with self.assertRaisesRegex(bridge.SessionBindingError, 'BOUND_SESSION_LOST'):
            bridge.get_r_addin_url()
        self.assertEqual(bridge._target_session, 'A')

    def test_changed_identity_requires_explicit_reconnect(self):
        self.record()
        bridge.get_r_addin_url()
        self.record(token='new-token')
        with self.assertRaisesRegex(bridge.SessionBindingError, 'BOUND_SESSION_CHANGED'):
            bridge.get_r_addin_url()
        result = asyncio.run(bridge.call_tool('connect_session', {'session_name':'A'}))
        self.assertIn('Connected', result[0].text)
        self.assertIn('48878', bridge.get_r_addin_url())
        self.assertEqual(bridge._target_token, 'new-token')

    def test_multiple_sessions_require_selection(self):
        self.record()
        self.record('B', port=48879)
        with self.assertRaisesRegex(bridge.SessionBindingError, 'MULTIPLE_SESSIONS'):
            bridge.get_r_addin_url()
        result = asyncio.run(bridge.call_tool('list_sessions', {}))
        self.assertIn('Active R sessions (2)', result[0].text)

    def test_no_sessions_does_not_guess_port(self):
        self.assertIsNone(bridge.get_r_addin_url())
        tools = asyncio.run(bridge.list_tools())
        self.assertIn('list_sessions', [t.name for t in tools])

    def test_duplicate_identity_is_ambiguous(self):
        self.record()
        bridge.get_r_addin_url()
        (self.root / 'duplicate.json').write_bytes((self.root / 'A.json').read_bytes())
        with self.assertRaises(bridge.SessionBindingError):
            bridge.get_r_addin_url()
        reply = asyncio.run(bridge.call_tool('connect_session', {'session_name':'A'}))
        self.assertNotIn('Connected to session', reply[0].text)

    def test_mirrors_identical(self):
        self.assertEqual((ROOT/'clauder-mcp/src/clauder_mcp/server.py').read_bytes(), (ROOT/'inst/scripts/persistent_r_mcp.py').read_bytes())

    def test_settings_do_not_pick_an_unbound_or_lost_session(self):
        self.record(tool_sets=['core'], plot_auto=True)
        bridge.get_r_addin_url()
        self.assertTrue(bridge._session_info()['plot_auto'])
        self.record(tool_sets=['core'], plot_auto=False)
        self.assertFalse(bridge._session_info()['plot_auto'])
        (self.root/'A.json').unlink()
        self.record('B', port=48879)
        self.assertIsNone(bridge._session_info())
        bridge._target_session = None
        self.record('A')
        self.assertIsNone(bridge._session_info())


if __name__ == '__main__':
    unittest.main()
