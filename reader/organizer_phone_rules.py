"""Extracted from organizer_service.py by sync_reader.py; the lines are the service's own. Do not edit."""
import datetime as dt
import re

from dateutil.rrule import rrulestr


STATUS = {"task": ("open", "done", "dropped"), "project": ("active", "parked", "done", "dropped"),
          "decision": ("made", "dropped"), "resume": ("current", "dropped"),
          "routine": ("on", "off", "dropped"), "buy": ("open", "bought", "dropped"),
          "timer": ("running", "done", "dropped")}


WORDS = {"daily": "FREQ=DAILY", "every day": "FREQ=DAILY", "weekdays": "FREQ=WEEKLY;BYDAY=MO,TU,WE,TH,FR",
         "weekends": "FREQ=WEEKLY;BYDAY=SA,SU", "weekly": "FREQ=WEEKLY", "every week": "FREQ=WEEKLY",
         "fortnightly": "FREQ=WEEKLY;INTERVAL=2", "monthly": "FREQ=MONTHLY", "every month": "FREQ=MONTHLY",
         "yearly": "FREQ=YEARLY", "every year": "FREQ=YEARLY"}


DAYS = {"monday": "MO", "tuesday": "TU", "wednesday": "WE", "thursday": "TH", "friday": "FR",
        "saturday": "SA", "sunday": "SU"}


class Refused(Exception):
    pass


def now():
    return dt.datetime.now().astimezone()


def local(text):
    """A local date or date and time ("2026-10-04", "2026-10-04 16:00",
    "2026-10-04T16:00"), as an aware datetime; a date alone is its start."""
    t = str(text or "").strip().replace(" ", "T")
    if not t:
        return None
    try:
        d = dt.datetime.fromisoformat(t)
    except ValueError:
        raise Refused("not a date or time: %r (use YYYY-MM-DD or YYYY-MM-DD HH:MM)" % text)
    return d.astimezone() if d.tzinfo else d.replace(tzinfo=now().tzinfo)


def shown(d):
    return d.strftime("%Y-%m-%d %H:%M") if d else None


def rule_of(repeat):
    """An RFC 5545 RRULE from words or an RRULE ("" for none)."""
    r = str(repeat or "").strip()
    if not r:
        return ""
    low = r.lower()
    if low in WORDS:
        return WORDS[low]
    m = re.fullmatch(r"every ((?:mon|tues|wednes|thurs|fri|satur|sun)day(?:s)?(?:(?:,\s*|\s+and\s+)(?:mon|tues|wednes|thurs|fri|satur|sun)days?)*)", low)
    if m:
        days = [DAYS[d.rstrip("s")] for d in re.findall(r"[a-z]+day", m.group(1))]
        return "FREQ=WEEKLY;BYDAY=" + ",".join(days)
    r = r.upper().removeprefix("RRULE:")
    try:
        rrulestr(r, dtstart=now().replace(second=0, microsecond=0))
    except (ValueError, TypeError):
        raise Refused("not a repeat: %r (use daily, weekdays, weekly, monthly, every monday..., or an RRULE)" % repeat)
    return r


def occurrence(rec, after=None):
    """A repeating task's current occurrence: the first not yet done."""
    start = local(rec.get("start"))
    if not rec.get("repeat") or not start:
        return None
    done = local(rec.get("done_until"))
    rule = rrulestr(rec["repeat"], dtstart=start)
    o = rule.after(done, inc=False) if done else rule.after(start, inc=True)
    # an occurrence completed or skipped on its own (each is its own instance) is not the current one
    handled = set(rec.get("done_for") or []) | set(rec.get("skipped_for") or [])
    while o is not None and shown(o) in handled:
        o = rule.after(o, inc=False)
    return o


def when(rec):
    """When an open task is due: its repeat's occurrence, its due, its reminder."""
    if rec.get("repeat"):
        return occurrence(rec)
    return local(rec.get("due")) or local(rec.get("remind"))
