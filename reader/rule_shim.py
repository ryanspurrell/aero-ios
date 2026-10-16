"""The repeat-words-to-RRULE function the quick add is given (`rule_of`), copied unchanged in behaviour from the service that owns it."""
import datetime as dt
import re

from dateutil.rrule import rrulestr

# repeats said in words, as well as RFC 5545 RRULEs (a fixed list: nothing guessed)
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
