"""The phone's notification list (phone_bridge.upcoming) tells only what may be shown and only what is still to be answered.
Run with a Python that has lark: python AeroTests/test_phone_bridge_upcoming.py (invented records only)."""
import json
import os
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "reader"))
import phone_bridge as PB  # noqa: E402

NOW = "2026-10-20T08:00:00+00:00"


def rec(oid, **f):
    return {"oid": oid, "id": oid + "-v1", "rec": dict({"type": "task", "status": "open", "title": "t-" + oid, "locked": False}, **f)}


def fires(records, **extra):
    return json.loads(PB.call("upcoming", json.dumps(dict({"records": records, "now": NOW, "limit": 20}, **extra))))["ok"]


class Upcoming(unittest.TestCase):
    def test_a_task_not_marked_open_or_in_a_locked_list_is_not_told(self):
        recs = [rec("a", remind="2026-10-21 09:00"),
                rec("b", remind="2026-10-21 10:00", locked=True),
                rec("c", remind="2026-10-21 11:00", locked=None),
                rec("d", remind="2026-10-21 12:00", project="L"),
                {"oid": "L", "id": "L-v1", "rec": {"type": "project", "title": "Private list", "locked": True}}]
        self.assertEqual([x["oid"] for x in fires(recs)], ["a"])

    def test_a_repeat_time_done_or_skipped_on_its_own_is_not_told(self):
        r = rec("r", repeat="FREQ=DAILY", start="2026-10-19 09:00", done_for=["2026-10-21 09:00"], skipped_for=["2026-10-22 09:00"])
        self.assertEqual([x["fire"] for x in fires([r], days=5)], ["2026-10-20 09:00", "2026-10-23 09:00", "2026-10-24 09:00"])


if __name__ == "__main__":
    unittest.main()
