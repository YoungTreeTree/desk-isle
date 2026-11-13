"""Connection regressions; never touch the user's accounts or Codex config."""
import contextlib
import importlib.util
import io
import json
from pathlib import Path
import sys
import tempfile
import types
import unittest
from unittest.mock import Mock, patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "helpers/garmin"))


def load(name, filename):
    spec = importlib.util.spec_from_file_location(name, ROOT / "helpers" / ("notifications" if filename == "install-codex-notifications.py" else "garmin") / filename)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


installer = load("installer", "install-codex-notifications.py")


class HookTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.file = Path(self.directory.name) / "hooks.json"

    def configure(self, command="new-helper hook codex", uninstall=False, previous=()):
        with contextlib.redirect_stdout(io.StringIO()):
            installer.configure(self.file, command, uninstall, previous)

    def test_migration_and_removal_preserve_unrelated_handlers(self):
        old, new, other = "old-helper hook codex", "new-helper hook codex", "another-app notify"
        third_party = {"type": "command", "command": other, "async": True, "timeout": 9}
        original = {"custom": 7, "hooks": {
            "Stop": [{"matcher": "custom", "extra": "keep", "hooks": [
                {"type": "command", "command": old}, third_party]}],
            "UnrelatedEvent": [{"hooks": [third_party]}],
        }}
        raw = json.dumps(original).encode()
        self.file.write_bytes(raw)
        self.configure(previous=[old])
        saved = json.loads(self.file.read_text())
        self.assertEqual(saved["custom"], 7)
        self.assertEqual(saved["hooks"]["UnrelatedEvent"], original["hooks"]["UnrelatedEvent"])
        self.assertEqual(saved["hooks"]["Stop"][0], {"matcher": "custom", "extra": "keep", "hooks": [third_party]})
        for event in installer.EVENTS:
            own = [h for g in saved["hooks"][event] for h in g["hooks"] if h["command"] == new]
            self.assertEqual(len(own), 1)
            self.assertEqual(own[0].get("async", False), event not in installer.SYNCHRONOUS_EVENTS)
        self.assertEqual(next(self.file.parent.glob("*.bak")).read_bytes(), raw)
        unchanged = self.file.read_bytes()
        self.configure(previous=[old])
        self.assertEqual(self.file.read_bytes(), unchanged)
        self.configure(uninstall=True, previous=[old])
        remaining = json.loads(self.file.read_text())
        self.assertEqual(remaining["hooks"]["Stop"][0]["hooks"], [third_party])
        self.assertEqual(set(remaining["hooks"]), {"Stop", "UnrelatedEvent"})

    def test_invalid_config_is_never_overwritten(self):
        for content in [b"broken", b"[]", b'{"hooks":[]}', b'{"hooks":{"Stop":42}}']:
            self.file.write_bytes(content)
            with self.assertRaises((ValueError, TypeError, AttributeError)):
                self.configure()
            self.assertEqual(self.file.read_bytes(), content)
        self.assertEqual(list(self.file.parent.glob("*.bak")), [])

    def test_symlink_is_not_replaced(self):
        target = self.file.with_name("actual.json")
        target.write_text("{}")
        self.file.symlink_to(target)
        with self.assertRaises(ValueError):
            self.configure()
        self.assertTrue(self.file.is_symlink())
        self.assertEqual(target.read_text(), "{}")

    def test_concurrent_edits_are_preserved(self):
        self.file.write_text("{}")
        read = Path.read_bytes
        calls = 0
        def concurrent_read(path):
            nonlocal calls
            if path == self.file:
                calls += 1
                if calls == 2:
                    path.write_text('{"edited":true}')
            return read(path)
        with patch.object(Path, "read_bytes", concurrent_read):
            with self.assertRaisesRegex(ValueError, "刚刚被修改"):
                self.configure()
        self.assertEqual(self.file.read_text(), '{"edited":true}')
        self.assertEqual(list(self.file.parent.iterdir()), [self.file])


class GarminTests(unittest.TestCase):
    def setUp(self):
        dependency = types.ModuleType("garminconnect")
        dependency.Garmin = Mock()
        dependency.GarminConnectAuthenticationError = type("AuthenticationError", (Exception,), {})
        dependency.GarminConnectConnectionError = type("ConnectionError", (Exception,), {})
        with patch.dict(sys.modules, {"garminconnect": dependency}):
            self.helper = load("garmin_test", "garmin_snapshot.py")
        self.dependency = dependency
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.session = Path(self.directory.name)
        self.pair = [{"domain": "garmin.cn", "oauth_token": "test-only", "oauth_token_secret": "test-only"},
                     {"access_token": "test-only", "refresh_token": "test-only"}]

    def test_china_directory_and_local_timezone_are_used(self):
        session = self.session / "session.json"
        session.write_text(json.dumps(self.pair))
        import base64
        self.dependency.Garmin.return_value.garth.dumps.return_value = base64.b64encode(json.dumps(self.pair).encode()).decode()
        with patch.object(self.helper.signal, "alarm"), \
             patch.object(self.helper, "fetch_snapshot", return_value={"steps": 5}) as fetch, \
             contextlib.redirect_stdout(io.StringIO()) as stdout:
            self.assertEqual(self.helper.main(["--session-file", str(session)]), 0)
        self.dependency.Garmin.assert_called_once_with(is_cn=True)
        self.dependency.Garmin.return_value.login.assert_called_once()
        self.assertEqual(json.loads(session.read_text()), self.pair)
        self.assertEqual(session.stat().st_mode & 0o777, 0o600)
        from datetime import datetime
        self.assertEqual(fetch.call_args.args[1].utcoffset(), datetime.now().astimezone().utcoffset())
        self.assertEqual(json.loads(stdout.getvalue()), {"steps": 5})

    def test_non_china_sessions_are_rejected_before_network_access(self):
        for value in ['[{"domain":"garmin.com"},{}]', '{}', 'null']:
            session = self.session / "session.json"
            session.write_text(value)
            with patch.object(self.helper.signal, "alarm"):
                self.assertEqual(self.helper.main(["--session-file", str(session)]), 2)
        self.dependency.Garmin.return_value.login.assert_not_called()

    def test_refresh_cannot_recreate_logged_out_session(self):
        from garmin_session import save
        import base64
        self.dependency.Garmin.return_value.garth.dumps.return_value = base64.b64encode(json.dumps(self.pair).encode()).decode()
        session = self.session / "removed" / "session.json"
        with self.assertRaises(FileNotFoundError):
            save(self.dependency.Garmin.return_value, session)
        self.assertFalse(session.parent.exists())

    def test_login_and_mfa_save_session_without_printing_credentials(self):
        import base64
        dependency = self.dependency
        dependency.GarminConnectTooManyRequestsError = type("RateLimit", (Exception,), {})
        with patch.dict(sys.modules, {"garminconnect": dependency}):
            auth = load("garmin_auth_test", "garmin_auth.py")
        client = dependency.Garmin.return_value
        client.get_full_name.return_value = "Test user"
        client.garth.dumps.return_value = base64.b64encode(json.dumps(self.pair).encode()).decode()
        def login():
            self.assertEqual(dependency.Garmin.call_args.kwargs["prompt_mfa"](), "123456")
        client.login.side_effect = login
        session = self.session / "session.json"
        incoming = '{"email":"test@example.invalid","password":"private-test"}\n{"code":"123456"}\n'
        with patch.object(auth.signal, "alarm"), patch.object(auth.signal, "signal"), \
             patch.object(sys, "stdin", io.StringIO(incoming)), contextlib.redirect_stdout(io.StringIO()) as output:
            self.assertEqual(auth.main(["--session-file", str(session)]), 0)
        self.assertEqual([json.loads(line)["type"] for line in output.getvalue().splitlines()], ["mfa", "success"])
        self.assertNotIn("private-test", output.getvalue())
        self.assertNotIn("test-only", output.getvalue())
        self.assertTrue(dependency.Garmin.call_args.kwargs["is_cn"])
        self.assertEqual(json.loads(session.read_text()), self.pair)

    def test_failed_login_never_saves_session_or_raw_error(self):
        dependency = self.dependency
        dependency.GarminConnectTooManyRequestsError = type("RateLimit", (Exception,), {})
        with patch.dict(sys.modules, {"garminconnect": dependency}):
            auth = load("garmin_auth_failure_test", "garmin_auth.py")
        dependency.Garmin.return_value.login.side_effect = dependency.GarminConnectAuthenticationError("sensitive-server-details")
        session = self.session / "session.json"
        with patch.object(auth.signal, "alarm"), patch.object(auth.signal, "signal"), \
             patch.object(sys, "stdin", io.StringIO('{"email":"test@example.invalid","password":"private-test"}\n')), \
             contextlib.redirect_stdout(io.StringIO()) as output:
            self.assertEqual(auth.main(["--session-file", str(session)]), 1)
        self.assertEqual(json.loads(output.getvalue()), {"type": "error", "code": "authentication"})
        self.assertFalse(session.exists())


if __name__ == "__main__":
    unittest.main()
