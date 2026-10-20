"""The few calls the iPhone app makes into the embedded Python (the reader and the day's arrangement), JSON in and JSON out.

The simplest model: the phone keeps its records itself (Swift, SQLite); when it needs to READ words or ARRANGE a day it asks the same
Python the PC uses, unchanged: Fingus Core's reader, Organizer's quick-add vocabulary and Organizer's timeline. Nothing here reads or
writes a file, a network or a database; every call is a pure function of what it is given.

    call(name, json_text) -> json_text      name: "quickadd", "calendar", "upcoming", "occurrence", "target", "clean"

Nothing in this file is a copy of the reader. sync_reader.py puts the real modules beside it at build time.
"""
import datetime as dt
import json

import organizer_phone_rules as R          # the PC service's own date and repeat helpers, extracted from organizer_service.py
import organizer_quickadd as QA
import organizer_timeline as TL

QUICK_LIMIT = 8                            # the most readings the PC keeps (organizer_quickadd.KEEP_READINGS)


def _plain(o):
    if isinstance(o, (set, frozenset)):
        return sorted(o, key=str)
    return str(o)


def _now(text):
    t = dt.datetime.fromisoformat(text)
    return t if t.tzinfo else t.astimezone()


class _Book:
    """What the timeline reads of a Book: `now`, {oid: {"id", "rec"}}."""

    def __init__(self, records):
        self.now = {r["oid"]: {"id": r["id"], "rec": r["rec"]} for r in records}
        self.versions = {}


def _shown(book, rec):
    """Whether a task's words may be shown on the phone, which is never in Locked mode (the service's visible_now with Locked mode off): the
    one gate, `organizer_timeline.may_show` (BranchOrganizerDay/Visible.lean `mayShow`): the task and its list each marked Open and not
    private; unmarked is private."""
    return TL.may_show(rec, book.now[rec["project"]]["rec"] if isinstance(rec.get("project"), str) and rec["project"] in book.now else None)


# The fields a record may carry (the service's FIELDS), so nothing else is copied from a reading into a record.
ALLOWED = {"title", "notes", "attention", "project", "parent", "due", "remind", "repeat", "start", "status", "goal", "why", "done", "blocker",
           "next_action", "what", "folder", "urgent", "color", "icon", "sections", "section", "collapsed", "quantity", "store", "cost",
           "size", "link", "want", "ordered", "expected", "timing", "category", "readings", "part_of_day", "links"}


def _readings(v):
    """The readings as the service keeps them (clean(), `readings`): every kept reading with its likelihood and the items it makes."""
    kept = []
    for x in v.get("kept") or []:
        kept.append({"label": str(x.get("label") or "")[:200], "likelihood": round(float(x["likelihood"]), 3),
                     "items": [{"type": str(i.get("type") or "task"), "args": {k: b for k, b in i["args"].items() if k in ALLOWED}} for i in x["items"]],
                     **{k: str(x[k])[:200] for k in ("choice", "why") if x.get(k)}})
    out = dict({k: v[k] for k in ("basis", "order", "ask", "why", "answered_at", "picked", "kind", "assumed") if k in v}, state=v["state"], kept=kept)
    if isinstance(v.get("asks"), list):
        out["asks"] = [str(x)[:300] for x in v["asks"]][:6]
    return out


def clean(a):
    """Fields in the forms a record keeps them: times as 'YYYY-MM-DD HH:MM', a repeat as an RRULE (what the service's clean() does for
    these), only the fields a record may carry. Used for a change made by hand or by a choice among readings."""
    out = {}
    for k, v in (a.get("fields") or {}).items():
        if k not in ALLOWED or v is None:
            continue
        if k in ("due", "remind", "start"):
            v = R.shown(R.local(v)) if v else None
        elif k == "repeat":
            v = R.rule_of(v)
        elif k == "readings":
            v = _readings(v)
        elif isinstance(v, str):
            v = v.strip()[:4000]
        out[k] = v
    return out


def capture(args):
    """The record a new item starts as (the service's `capture`): its type, title, first status, the words as typed, and its fields."""
    kind = args.get("type") or "task"
    title = str(args.get("title") or args.get("text") or "").strip()
    if not title:
        raise ValueError("a title is needed")
    rec = {"type": kind, "title": title[:400], "status": R.STATUS[kind][0]}
    if kind == "task":
        rec["attention"] = "inbox"
    if kind == "buy":
        rec["want"] = "need"
    rec["capture"] = str(args.get("text") or title)[:400] if args.get("title") else title
    rec.update(clean({"fields": {k: v for k, v in args.items() if k not in ("title", "type", "text", "status", "from")}}))
    return rec


def occurrence_of(a):
    """A repeating task's current occurrence ('YYYY-MM-DD HH:MM'), the one a tick settles."""
    return {"at": R.shown(R.occurrence(a["rec"]))}


def quickadd(a):
    """One typed line read as the service's `quickadd` reads it. Returns what the phone makes records of:
    {first: the item (type and fields, with the readings kept when the line is not certain), more: further items, ask, says, ...}."""
    now = _now(a["now"])
    lists = [{"id": x["id"], "title": x.get("title")} for x in a.get("lists") or []]
    woke = R.local(a["woke"]) if a.get("woke") else None
    got = QA.understand(a.get("text"), now, woke, lists, R.rule_of, a.get("where") if isinstance(a.get("where"), dict) else None, None, None)
    first = dict(got["args"], type=got["type"])
    if got.get("readings"):
        first["readings"] = got["readings"]
    more = [dict(it["args"], type=it["type"]) for it in got["items"][1:]]
    first, more = capture(first), [capture(m) for m in more]
    return {"first": first, "more": more, "ask": (got.get("readings") or {}).get("ask"), "says": got.get("says"),
            "plain": got.get("plain"), "understood": got.get("understood"), "unsure": got.get("unsure")}


def calendar(a):
    """The `calendar` answer (organizer_timeline.calendar_view) over the records the phone holds. `records`: the current version of each
    record, [{oid, id, rec}]. The phone has no Colony: events are empty and Locked mode is off, so only records marked Open show."""
    t = _now(a["now"])
    day = R.local(a["date"]).date() if a.get("date") else t.date()
    book = _Book(a["records"])
    lists = {o: i["rec"] for o, i in book.now.items() if i["rec"].get("type") == "project"}
    return TL.calendar_view(book, a.get("span") or "day", day, t, False, R.local, R.when, [], lists, a.get("mode") or TL.DEFAULT_MODE, "", None)


def _timed(d):
    """Whether a put-off carries an hour: what was recorded (`timed`), else whether the time written has one (a date alone does not)."""
    return d["timed"] if isinstance(d.get("timed"), bool) else len(str(d.get("until") or "").strip()) > 10


def upcoming(a):
    """The next times something should be told, nearest first: [{oid, title, fire}] with `fire` 'YYYY-MM-DD HH:MM' (local). Open tasks
    with a reminder time in the future, and each repeating task's next times; a date with no hour is not a time to be told. A task put off
    is told at its new time, once (BranchOrganizerDay/Spread.lean `singleFires`, `repeatFires`): nothing is told before that time, and a
    repeat's current time that was moved is not also told at its old time."""
    t = _now(a["now"])
    limit = int(a.get("limit") or 64)
    horizon = t + dt.timedelta(days=int(a.get("days") or 120))
    out = []
    book = _Book(a["records"])
    for r in a["records"]:
        rec = r["rec"]
        if rec.get("type") != "task" or rec.get("status") != "open" or rec.get("aside"):
            continue
        if not _shown(book, rec):
            continue            # the phone is never in Locked mode: a task not marked Open, or in a Locked list, is not told (its title would reach the lock screen)
        d = rec.get("deferred") or {}
        hold = R.local(d["until"]) if d.get("until") else None
        title, told = rec.get("title") or "", set()

        def tell(at):
            if at not in told:
                told.add(at)
                out.append((at, r["oid"], title))
        if hold and _timed(d) and hold > t:
            tell(hold)                                     # put off to a time with an hour: told there, whatever else is set
        if rec.get("repeat") and rec.get("start"):
            from dateutil.rrule import rrulestr
            try:
                rule = rrulestr(rec["repeat"], dtstart=R.local(rec["start"]))
                done = R.local(rec["done_until"]) if rec.get("done_until") else None
                handled = set(rec.get("done_for") or []) | set(rec.get("skipped_for") or [])      # a time done or skipped on its own is not told
                current = R.occurrence(rec) if hold else None                                      # the time a put-off moved
                n = 0
                for o in rule.xafter(max(t, done) if done else t, count=limit, inc=False) if hasattr(rule, "xafter") else rule.between(t, horizon, inc=False)[:limit]:
                    if o > horizon or n >= limit:
                        break
                    if (o.hour or o.minute) and not (hold and (o < hold or o == current)) and R.shown(o) not in handled:
                        tell(o)
                        n += 1
            except (ValueError, TypeError):
                pass
            continue
        w = rec.get("remind")
        if not w or len(str(w)) <= 10:
            continue
        at = R.local(w)
        if at > t and not (hold and at < hold):
            tell(at)
    out.sort(key=lambda x: (x[0], x[1]))
    return [{"oid": o, "title": title, "fire": at.strftime("%Y-%m-%d %H:%M")} for at, o, title in out[:limit]]


def target_of(a):
    """The time a Done or Skip on a repeating task is for: the one the button named, which must be one of the task's own times, else the
    current one (the service's `repeat_target`, same lines). A time the rule does not have is an error, and nothing is written."""
    rec, wanted = a["rec"], a.get("occurrence") or ""
    current = R.occurrence(rec)
    if not wanted:
        return {"at": R.shown(current), "current": R.shown(current)}
    o = R.local(wanted)
    start = R.local(rec.get("start"))
    from dateutil.rrule import rrulestr
    if o is None or start is None or not rrulestr(rec["repeat"], dtstart=start).between(o, o, inc=True):
        raise ValueError("that is not one of its times")
    return {"at": R.shown(o), "current": R.shown(current)}


def loaded(_a):
    """The standard library's .py files imported so far, relative to its folder, sorted: what the app's bundle has to keep (the build
    trims the rest, measured from this list)."""
    import json
    import os
    import sys
    root = os.path.dirname(os.path.dirname(os.path.abspath(json.__file__)))      # os is frozen in 3.13 and may have no __file__; json is not
    return sorted(os.path.relpath(m.__file__, root) for m in list(sys.modules.values())
                  if str(getattr(m, "__file__", "") or "").endswith(".py") and os.path.abspath(m.__file__).startswith(root + os.sep)
                  and "site-packages" not in m.__file__ and "app_packages" not in m.__file__)


CALLS = {"loaded": loaded,"quickadd": quickadd, "calendar": calendar, "upcoming": upcoming, "clean": clean, "occurrence": occurrence_of,
         "target": target_of}


def call(name, text):
    try:
        return json.dumps({"ok": CALLS[name](json.loads(text))}, default=_plain, ensure_ascii=False)
    except Exception as e:      # the phone shows a plain sentence; the type and words go with it for whoever reads the log
        return json.dumps({"error": "%s: %s" % (type(e).__name__, e)}, ensure_ascii=False)
