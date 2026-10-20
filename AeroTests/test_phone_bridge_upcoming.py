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


    def test_a_task_marked_open_but_private_is_not_told_and_an_unmarked_list_does_not_make_its_tasks_open(self):
        recs = [rec("a", remind="2026-10-21 09:00", private=True),
                rec("b", remind="2026-10-21 10:00", project="L"),
                {"oid": "L", "id": "L-v1", "rec": {"type": "project", "title": "Old list"}}]            # a list made before the marker: unmarked is private
        self.assertEqual(fires(recs), [])

    def test_a_task_put_off_is_told_at_its_new_time_once_and_not_at_the_old_one(self):
        r = rec("a", remind="2026-10-21 09:00", deferred={"until": "2026-10-21 10:00", "times": 1, "timed": True})
        self.assertEqual([x["fire"] for x in fires([r])], ["2026-10-21 10:00"])
        same = rec("b", remind="2026-10-21 10:00", deferred={"until": "2026-10-21 10:00", "times": 1, "timed": True})
        self.assertEqual([x["fire"] for x in fires([same])], ["2026-10-21 10:00"], "one notice for one time")
        date_only = rec("c", remind="2026-10-21 09:00", deferred={"until": "2026-10-22", "times": 1, "timed": False})
        self.assertEqual([x["fire"] for x in fires([date_only])], [], "put off to a date with no hour: the old time waits and the date is not a time to be told")

    def test_a_repeats_current_time_that_was_moved_is_told_at_the_new_time_only(self):
        r = rec("r", repeat="FREQ=DAILY", start="2026-10-19 09:00", done_until="2026-10-20 09:00",
                deferred={"until": "2026-10-21 11:30", "times": 1, "timed": True})
        got = [x["fire"] for x in fires([r], days=3)]
        self.assertEqual(got[:2], ["2026-10-21 11:30", "2026-10-22 09:00"])
        self.assertNotIn("2026-10-21 09:00", got)

    def test_the_time_a_button_names_must_be_one_of_the_tasks_own(self):
        r = {"type": "task", "status": "open", "title": "t", "locked": False, "repeat": "FREQ=DAILY", "start": "2026-10-19 09:00"}
        ok = json.loads(PB.call("target", json.dumps({"rec": r, "occurrence": "2026-10-22 09:00"})))
        self.assertEqual(ok["ok"]["at"], "2026-10-22 09:00")
        none = json.loads(PB.call("target", json.dumps({"rec": r, "occurrence": ""})))
        self.assertEqual(none["ok"]["at"], none["ok"]["current"])
        for bad in ("2026-10-22 09:01", "2026-10-18 09:00", "nonsense"):
            self.assertIn("error", json.loads(PB.call("target", json.dumps({"rec": r, "occurrence": bad}))), bad)


if __name__ == "__main__":
    unittest.main()
