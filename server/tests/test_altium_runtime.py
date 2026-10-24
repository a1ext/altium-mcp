"""Unit tests for altium_runtime (pure Python, no Altium needed).

Run from the repo root:  python -m unittest server.tests.test_altium_runtime -v
or from server/:          python -m unittest tests.test_altium_runtime -v
"""
import asyncio
import json
import os
import sys
import tempfile
import time
import unittest
from pathlib import Path

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))

import altium_runtime as rt  # noqa: E402

TEMPLATE = Path(__file__).resolve().parent.parent / "SandboxScript" / "Sandbox.template.pas"


class TempExchange(unittest.TestCase):
    """Points the runtime's exchange files at a temporary folder."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        d = Path(self.tmp.name)
        self.saved = {k: getattr(rt, k) for k in
                      ("EXCHANGE_DIR", "REQUEST_FILE", "LOCK_FILE", "INFLIGHT_FILE")}
        rt.EXCHANGE_DIR = d
        rt.REQUEST_FILE = d / "request.json"
        rt.LOCK_FILE = d / "bridge.lock"
        rt.INFLIGHT_FILE = d / "inflight.json"

    def tearDown(self):
        for k, v in self.saved.items():
            setattr(rt, k, v)
        rt._local_lock = None
        self.tmp.cleanup()


class RequestTest(TempExchange):
    def test_layout_matches_the_pascal_reader(self):
        rt.write_request("move_components",
                         {"designators": ["U1", "BUS[3]", "R,1"], "x_offset": 10.5,
                          "empty": [], "path": "C:\\a\\µ.SchLib"}, "abc123")
        text = rt.REQUEST_FILE.read_text(encoding="ascii")  # ASCII only
        lines = text.splitlines()
        # every top-level key on its own line with exactly two spaces
        for key in ("request_id", "command", "designators", "x_offset", "empty", "path"):
            self.assertTrue(any(l.startswith(f'  "{key}":') for l in lines), key)
        self.assertIn('  "empty": [],', lines)
        # array elements one per line, closing bracket alone
        i = lines.index('  "designators": [')
        self.assertEqual(lines[i + 1:i + 5], ['    "U1",', '    "BUS[3]",', '    "R,1"', '  ],'])
        self.assertIn("\\u00b5", text)
        self.assertEqual(json.loads(text)["request_id"], "abc123")
        self.assertEqual(list(rt.EXCHANGE_DIR.glob("*.tmp")), [])

    def test_read_json_file_waits_for_a_complete_file(self):
        p = rt.EXCHANGE_DIR / "r.json"
        p.write_text('{"success": tr', encoding="utf-8")

        async def go():
            async def finish():
                await asyncio.sleep(0.4)
                p.write_text('{"success": true}', encoding="utf-8")
            asyncio.ensure_future(finish())
            return await rt.read_json_file(p, lambda q: q.read_text(encoding="utf-8"))

        self.assertEqual(asyncio.run(go()), {"success": True})

    def test_inflight_roundtrip(self):
        self.assertIsNone(rt.read_inflight())
        rt.set_inflight("command", "id1", "get_all_nets", rt.EXCHANGE_DIR / "x.json")
        self.assertEqual(rt.read_inflight()["id"], "id1")
        rt.clear_inflight()
        self.assertIsNone(rt.read_inflight())


class LockTest(TempExchange):
    def test_reentrant_within_a_call(self):
        async def go():
            async with rt.altium_lock(2) as outer:
                async with rt.altium_lock(2) as inner:
                    return outer, inner
        self.assertEqual(asyncio.run(go()), (True, True))

    def test_held_by_another_process(self):
        import msvcrt
        other = open(rt.LOCK_FILE, "a+b")
        try:
            other.seek(0)
            msvcrt.locking(other.fileno(), msvcrt.LK_NBLCK, 1)

            async def go():
                async with rt.altium_lock(1) as acquired:
                    return acquired
            self.assertFalse(asyncio.run(go()))
        finally:
            other.seek(0)
            msvcrt.locking(other.fileno(), msvcrt.LK_UNLCK, 1)
            other.close()

    def test_calls_in_one_process_take_turns(self):
        order = []

        async def call(name):
            async with rt.altium_lock(5) as acquired:
                self.assertTrue(acquired)
                order.append(name + " in")
                await asyncio.sleep(0.2)
                order.append(name + " out")

        async def go():
            await asyncio.gather(call("a"), call("b"))
        asyncio.run(go())
        self.assertEqual(order, ["a in", "a out", "b in", "b out"])


class SandboxSourceTest(unittest.TestCase):
    def setUp(self):
        self.template = TEMPLATE.read_text(encoding="utf-8").replace("\r\n", "\n")

    def test_body_and_run_id(self):
        src = rt.sandbox_source(self.template, "        ResultText := 'x';", "r42")
        self.assertIn("SBX_RUN_ID = 'r42';", src)
        self.assertIn("ResultText := 'x';", src)
        self.assertNotIn("{\"probe\": \"alive\"}", src)
        self.assertEqual(src.count(rt.SANDBOX_BEGIN), 1)
        self.assertEqual(src.count(rt.SANDBOX_END), 1)

    def test_template_is_the_probe(self):
        self.assertIn("SBX_RUN_ID = '';", self.template)
        self.assertIn("ResultText := '{\"probe\": \"alive\"}';", self.template)

    def test_missing_run_id_constant(self):
        with self.assertRaises(ValueError):
            rt.sandbox_source(self.template.replace("SBX_RUN_ID", "X"), "", "r1")

    def test_files_per_run(self):
        log, result, go = rt.sandbox_files("r9")
        self.assertTrue(str(result).endswith("sandbox_result_r9.json"))
        self.assertTrue(str(go).endswith("sandbox_go_r9"))
        self.assertIsNone(rt.sandbox_files("")[2])


class DialogTest(unittest.TestCase):
    def test_acknowledgements_are_closed(self):
        self.assertTrue(rt.classify_dialog("TMessageForm", "Error", ["OK"], False))
        self.assertTrue(rt.classify_dialog("#32770", "Information", ["&OK"], False))
        self.assertTrue(rt.classify_dialog("TForm_RunScriptParameters", "Select Item To Run",
                                           [], False))

    def test_questions_are_left_to_the_user(self):
        self.assertFalse(rt.classify_dialog("TMessageForm", "Warning", ["Yes", "No"], False))
        self.assertFalse(rt.classify_dialog("TMessageForm", "Confirm", ["OK", "Cancel"], False))
        self.assertFalse(rt.classify_dialog("#32770", "Save As", ["&Save", "Cancel"], True))
        self.assertFalse(rt.classify_dialog("TMessageForm", "Error", [], False))

    def test_script_file_prompts_while_a_script_is_in_front(self):
        self.assertTrue(rt.classify_dialog("TMessageForm", "Confirm", ["Yes", "No"], True))


class LaunchTest(TempExchange):
    def test_relaunch_after_busy_instance(self):
        done = rt.EXCHANGE_DIR / "response_x.json"
        launches = []
        calls = {"n": 0}
        busy = {"hwnd": 1, "title": "Information", "buttons": ["OK"], "busy_instance": True,
                "class": "#32770", "message": "busy", "closable": True}

        def fake_close():
            calls["n"] += 1
            if calls["n"] == 1:
                return [busy], []
            if len(launches) >= 2:
                done.write_text("{}", encoding="utf-8")
            return [], []

        saved = rt.launch, rt.close_dialogs, rt.altium_hung
        rt.launch, rt.close_dialogs, rt.altium_hung = launches.append, fake_close, lambda: True
        try:
            outcome = asyncio.run(rt.launch_and_wait("cmd", done, timeout=15, settle=0))
        finally:
            rt.launch, rt.close_dialogs, rt.altium_hung = saved
        self.assertTrue(outcome["done"])
        self.assertEqual(outcome["launches"], 2)
        self.assertEqual(launches, ["cmd", "cmd"])

    def test_idle_altium_ends_the_wait_early(self):
        saved = rt.launch, rt.close_dialogs, rt.altium_hung
        rt.launch, rt.close_dialogs, rt.altium_hung = (lambda c: None), (lambda: ([], [])), (lambda: False)
        try:
            start = time.time()
            outcome = asyncio.run(rt.launch_and_wait(
                "cmd", rt.EXCHANGE_DIR / "never.json", timeout=30, settle=0, idle_exit=1))
        finally:
            rt.launch, rt.close_dialogs, rt.altium_hung = saved
        self.assertFalse(outcome["done"])
        self.assertTrue(outcome["idle"])
        self.assertLess(time.time() - start, 5)

    def test_busy_altium_is_waited_for(self):
        saved = rt.launch, rt.close_dialogs, rt.altium_hung
        rt.launch, rt.close_dialogs, rt.altium_hung = (lambda c: None), (lambda: ([], [])), (lambda: True)
        try:
            outcome = asyncio.run(rt.launch_and_wait(
                "cmd", rt.EXCHANGE_DIR / "never.json", timeout=3, settle=0, idle_exit=1))
        finally:
            rt.launch, rt.close_dialogs, rt.altium_hung = saved
        self.assertFalse(outcome["idle"])
        self.assertGreaterEqual(outcome["elapsed"], 3)


class AsciiPascalTest(unittest.TestCase):
    def test_literals_get_character_codes(self):
        self.assertEqual(rt.ascii_pascal("S1 := 'µΩ';"), "S1 := ''+#181+''+#937+'';")
        self.assertEqual(rt.ascii_pascal("S1 := 'a''Ж';"), "S1 := 'a'''+#1046+'';")

    def test_outside_literals_becomes_question_mark(self):
        self.assertEqual(rt.ascii_pascal("// тест\nS1 := 'ok';"), "// ????\nS1 := 'ok';")

    def test_ascii_is_unchanged(self):
        src = "if (S1 = 'it''s') then ResultText := 'x';"
        self.assertEqual(rt.ascii_pascal(src), src)


if __name__ == "__main__":
    unittest.main()
