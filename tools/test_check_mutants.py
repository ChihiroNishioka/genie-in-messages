#!/usr/bin/env python3
"""Unit tests for the mutant result classifiers."""

import ast
import importlib.util
from pathlib import Path
import sys
import unittest

SCRIPT = Path(__file__).resolve().with_name("check-mutants.py")


class CheckMutantsTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.module = None
        try:
            tree = ast.parse(SCRIPT.read_text(encoding="utf-8"), filename=str(SCRIPT))
        except (OSError, SyntaxError) as error:
            cls.load_error = error
            return
        names = {
            node.name
            for node in tree.body
            if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef))
        }
        cls.missing = {"classify_build", "classify_test"} - names
        if cls.missing:
            return
        spec = importlib.util.spec_from_file_location("check_mutants_under_test", SCRIPT)
        if spec is None or spec.loader is None:
            cls.load_error = RuntimeError("could not create module spec")
            return
        module = importlib.util.module_from_spec(spec)
        sys.modules[spec.name] = module
        spec.loader.exec_module(module)
        cls.module = module

    def require_function(self, name):
        if self.module is None:
            missing = getattr(self, "missing", set())
            if name in missing:
                self.fail(f"check-mutants.py has no {name} function")
            self.fail(f"check-mutants.py could not be loaded: {getattr(self, 'load_error', 'unknown error')}")
        if not hasattr(self.module, name):
            self.fail(f"check-mutants.py has no {name} function")
        return getattr(self.module, name)

    def test_classify_build(self):
        classify_build = self.require_function("classify_build")
        self.assertEqual(classify_build(1), "BUILD_FAILED")

    def test_classify_test(self):
        classify_test = self.require_function("classify_test")
        target = "SplitReplyTests.testX"
        self.assertEqual(classify_test(0, "Executed 1 test", target), "SURVIVED")
        killed = "error: SplitReplyTests.testX : XCTAssertEqual failed\nTest Case 'SplitReplyTests.testX' failed"
        self.assertEqual(classify_test(1, killed, target), "KILLED")
        self.assertEqual(classify_test(1, killed + "\nFatal error: crash", target), "CRASHED")
        self.assertEqual(classify_test(1, "SplitReplyTests.testX : threw error\nTest Case 'SplitReplyTests.testX' failed", target), "ERRORED")
        self.assertEqual(classify_test(1, "no assertion output", target), "RUN_FAILED")
        self.assertEqual(classify_test(1, "SplitReplyTests.testX : XCTAssertEqual failed", target), "RUN_FAILED")
        other_test = "OtherTests.testY : XCTAssertEqual failed\nTest Case 'OtherTests.testY' failed"
        self.assertEqual(classify_test(1, other_test, target), "RUN_FAILED")
        self.assertEqual(classify_test(1, "Exited with signal code 11", target), "CRASHED")
        self.assertEqual(classify_test(1, "Exited with unexpected signal code 11", target), "CRASHED")
        linux = ("/x/SplitReplyTests.swift:15: error: SplitReplyTests.testX : XCTAssertEqual failed: (\"a\") is not equal to (\"b\") - \n"
                 "Test Case 'SplitReplyTests.testX' failed (0.106 seconds)")
        self.assertEqual(classify_test(1, linux, target), "KILLED")
        macos = ("/x/SplitReplyTests.swift:15: error: -[GenieCoreTests.SplitReplyTests testX] : XCTAssertEqual failed: (\"a\") is not equal to (\"b\")\n"
                 "Test Case '-[GenieCoreTests.SplitReplyTests testX]' failed (0.106 seconds).")
        self.assertEqual(classify_test(1, macos, target), "KILLED")
        prefix = "error: SplitReplyTests.testXY : XCTAssertEqual failed\nTest Case 'SplitReplyTests.testXY' failed (0.1 seconds)"
        self.assertEqual(classify_test(1, prefix, target), "RUN_FAILED")


if __name__ == "__main__":
    unittest.main()
