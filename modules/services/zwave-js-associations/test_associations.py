"""Unit tests for associations.py's planning and validation, which decide
every change made to a device; the zwave-js calls around them are thin."""

import unittest

from associations import AssociationError, plan, validate


class PlanTest(unittest.TestCase):
    def test_nothing_to_do(self):
        self.assertEqual(plan([{"nodeId": 13}, {"nodeId": 7}], [7, 13]), ([], []))

    def test_adds_missing(self):
        self.assertEqual(plan([{"nodeId": 13}], [13, 7]), ([{"nodeId": 7}], []))

    def test_removes_undeclared(self):
        # The kitchen switch still pointing at a node that is gone.
        self.assertEqual(
            plan([{"nodeId": 56}, {"nodeId": 53}], [53]), ([], [{"nodeId": 56}])
        )

    def test_adds_and_removes(self):
        self.assertEqual(
            plan([{"nodeId": 44}, {"nodeId": 45}], [44, 108]),
            ([{"nodeId": 108}], [{"nodeId": 45}]),
        )

    def test_endpoint_entries_are_removed(self):
        # Targets are declared as whole nodes; a multi channel entry is not one.
        self.assertEqual(
            plan([{"nodeId": 7, "endpoint": 1}], [7]),
            ([{"nodeId": 7}], [{"nodeId": 7, "endpoint": 1}]),
        )

    def test_empty_declaration_clears_group(self):
        self.assertEqual(plan([{"nodeId": 3}], []), ([], [{"nodeId": 3}]))

    def test_duplicates_in_declaration(self):
        self.assertEqual(plan([], [7, 7]), ([{"nodeId": 7}], []))


class ValidateTest(unittest.TestCase):
    def test_lifeline_refused(self):
        with self.assertRaises(AssociationError):
            validate({"19": {"1": [1]}})

    def test_self_target_refused(self):
        with self.assertRaises(AssociationError):
            validate({"19": {"2": [19]}})

    def test_normal_declaration(self):
        validate({"19": {"2": [13, 7]}, "97": {"2": [53]}})


if __name__ == "__main__":
    unittest.main()
