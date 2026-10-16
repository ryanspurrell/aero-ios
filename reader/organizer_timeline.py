"""The day, week, month and year as data (projects/aero/mockups/organizer_timeline_2026-10-15.html and organizer_calendar_views_2026-10-15.html).

The simplest model: Organizer's front is a calendar. Its things on a day are Organizer's tasks that have a time or a date, plus Colony's
calendar events for that day (read through Colony's own route, never copied; each stays its owner's, and tapping one opens the owner's).
This module only arranges them: for one day, a list of rows in the order they are drawn (time down the left, a Now line, free time said
as free, each thing with its colour and symbol, a question that is still open in place under its thing); the same day said as simply as it
can be (what is next, what is later, what was done said back); and for a week, a month and a year, the same things per day.

One answer is drawn by the phone page, the desktop page and the iPhone app (a board: aero_web.py ORGANIZER_DAY_BOARD). Pure functions
over Organizer's Book; the service gives them its clock, its parser and Colony's events. Standard library and python-dateutil only.

Colours and symbols (names the page draws from its theme, as a list's are): a task has its list's colour and symbol when the list has
them, else yellow-green ("accent") and "tasks"; a repeating task purple and "repeat"; a thing to buy green and "cart"; a calendar event
orange and "calendar". Picked, not grounded: they follow the approved mock; nothing says a person finds them easier.
"""
import calendar as _cal
import datetime as dt

from dateutil.rrule import rrulestr

LOOKS = {"task": ("accent", "tasks"), "repeat": ("purple", "repeat"), "buy": ("green", "cart"), "event": ("orange", "calendar")}
SPANS = ("day", "week", "month", "year")
MODES = ("timeline", "simple")
DEFAULT_MODE = "timeline"
ITEMS_MAX = 400                                     # a year of tasks and events, never more rows than this are built

# The first word of a task, said back in the past ("Take pills" -> "You took pills at 8:05"). Only words in this list are changed; a
# task that begins with any other word is said as "You finished take pills" so a wrong verb is never made up.
PAST = {"take": "took", "call": "called", "pay": "paid", "buy": "bought", "send": "sent", "water": "watered", "clean": "cleaned",
        "feed": "fed", "walk": "walked", "go": "went", "make": "made", "get": "got", "check": "checked", "book": "booked",
        "pick": "picked", "drop": "dropped", "return": "returned", "email": "emailed", "text": "texted", "order": "ordered",
        "wash": "washed", "cook": "cooked", "finish": "finished", "read": "read", "write": "wrote", "plan": "planned",
        "renew": "renewed", "reply": "replied", "tidy": "tidied", "stretch": "stretched", "eat": "ate", "see": "saw", "visit": "visited",
        "pack": "packed", "fill": "filled", "charge": "charged", "bring": "brought", "clear": "cleared", "do": "did",
        "put": "put", "mail": "mailed", "ring": "rang", "meet": "met", "sort": "sorted"}


def said_back(title, at_text):
    """What a done thing is said back as: 'You took pills at 8:05 AM'."""
    words = " ".join(str(title or "").split())
    first, _, rest = words.partition(" ")
    past = PAST.get(first.lower())
    body = (past + (" " + rest if rest else "")) if past else "finished " + words[:1].lower() + words[1:]
    return "You %s%s" % (body, " at " + at_text if at_text else "")


def clock_text(hhmm):
    """'16:05' as '4:05 PM'."""
    if not hhmm:
        return ""
    h, m = int(hhmm[:2]), hhmm[3:5]
    return "%d:%s %s" % (h % 12 or 12, m, "PM" if h >= 12 else "AM")


def span_text(minutes):
    """A wait said plainly: '20 min', '1 h 20 min', '2 h'."""
    minutes = max(0, int(round(minutes)))
    if minutes < 60:
        return "%d min" % minutes
    h, m = divmod(minutes, 60)
    return "%d h" % h if not m else "%d h %d min" % (h, m)


def span_words(minutes):
    """The same, in words for the simple view: '1 hour 20 minutes'."""
    minutes = max(0, int(round(minutes)))
    h, m = divmod(minutes, 60)
    bits = (["%d hour%s" % (h, "" if h == 1 else "s")] if h else []) + (["%d minute%s" % (m, "" if m == 1 else "s")] if m or not h else [])
    return " ".join(bits)


def question_of(oid, rec):
    """A quick-add question still open on this task, with one-tap choices (only a reading that is one plain item can be chosen). Each
    choice carries the change that answers it, the same `update` the item's own screen sends. None when there is none."""
    rd = rec.get("readings") or {}
    if rd.get("state") != "not answered" or rd.get("assumed"):
        return None
    choices = []
    for i, k in enumerate(rd.get("kept") or []):
        items = k.get("items") or []
        if len(items) == 1 and isinstance(items[0].get("args"), dict):
            choices.append({"index": i, "label": k.get("label") or "", "likelihood": k.get("likelihood"),
                            "answer": {"name": "update", "args": dict(items[0]["args"], id=oid[:8])}})
    if not choices:
        return None
    return {"id": oid[:8], "ask": rd.get("ask") or "", "capture": rec.get("capture") or rec.get("title") or "", "choices": choices}


LOOK_COLORS = ("accent", "second", "red", "orange", "yellow", "green", "teal", "blue", "purple", "pink", "brown", "grey")
LOOK_ICONS = ("list", "tasks", "cart", "book", "place", "home", "heart", "money", "music", "code", "star", "flag", "gift", "calendar",
              "doc", "person", "food", "clock", "repeat")
_LOOKS = [LOOKS]                                     # the kinds' looks for this answer (the person's own over the defaults)


def _entry(source, kind, key, title, date, time="", end="", all_day=False, state="open", done_at="", since="", color=None, icon=None,
           repeat=False, ref=None, question=None):
    c, i = _LOOKS[0][kind]
    return {"source": source, "type": kind, "id": key, "title": title, "date": date.isoformat(), "time": time, "time_text": clock_text(time),
            "end": end, "end_text": clock_text(end), "all_day": all_day, "state": state, "done_at": done_at, "done_at_text": clock_text(done_at),
            "since": since, "color": color or c, "icon": icon or i, "repeat": repeat, "open": ref or {"app": "organizer", "id": key},
            "question": question}


def _hm(d):
    return d.strftime("%H:%M")


def _has_time(text):
    """A stored time carries an hour; midnight is how a date alone is kept, so it is read as no time."""
    t = str(text or "").strip()
    return len(t) > 10 and t[11:16] != "00:00"


def entries_between(book, first, last, today, locked_on, local, when, events, lists):
    """(A thing's colour is data its owner keeps and every surface draws as given: a list's colour, a kind's colour the person set (or
    the default above), a calendar event's own calendar colour from Colony, a hex value. Nothing draws a colour of its own.)
    Every thing on the days first..last (dates, inclusive) as {date: [entry]}: Organizer's tasks that have a time or a date (a repeat on
    each day it falls; what was done on the day it was done; an open one from before, on today only, as 'from before'), and Colony's
    events. A task not marked Open (Locked, or made before the marker) only while Locked mode is on: unchecked is private. A task put off
    or set aside is not shown. A task that is a calendar event's time is shown once, as the task. `lists`: {project id: record}."""
    out = {}
    cap = [ITEMS_MAX]

    def put(entry):
        if cap[0] > 0:
            out.setdefault(entry["date"], []).append(entry)
            cap[0] -= 1

    start = dt.datetime.combine(first, dt.time(), local("2000-01-01").tzinfo)
    stop = dt.datetime.combine(last, dt.time(23, 59, 59), start.tzinfo)
    scheduled = set()
    for oid, item in book.now.items():
        rec = item["rec"]
        if rec.get("type") == "task" and rec.get("status") == "open" and rec.get("event"):
            scheduled.add(rec["event"])
    for oid, item in book.now.items():
        rec = item["rec"]
        if rec.get("type") != "task" or rec.get("aside") or (rec.get("locked") is not False and not locked_on):
            continue
        # a list that is Locked makes its tasks Locked
        proj = lists.get(rec.get("project")) or {}
        if (proj.get("locked") or proj.get("private")) and not locked_on:
            continue
        title = rec.get("title") or ""
        look = {"color": proj.get("color") if proj.get("color") else None, "icon": proj.get("icon") if proj.get("icon") else None}
        d = rec.get("deferred") or {}
        if d.get("until") and local(d["until"]) > local(today.isoformat() + " 00:00"):
            continue
        kind = "buy" if rec.get("type") == "buy" else "repeat" if rec.get("repeat") else "task"
        q = question_of(oid, rec)
        key = oid[:8]
        if rec.get("repeat") and rec.get("start"):
            try:
                rule = rrulestr(rec["repeat"], dtstart=local(rec["start"]))
                times = rule.between(start, stop, inc=True)[:ITEMS_MAX]
            except (ValueError, TypeError):
                times = []
            done_until = local(rec.get("done_until")) if rec.get("done_until") else None
            for o in times:
                ticked = bool(done_until and o <= done_until)
                if o.date() < today and not ticked:
                    continue                                     # a past time nobody ticked: not claimed either way
                put(_entry("organizer", kind, key, title, o.date(), _hm(o) if (o.hour or o.minute) else "", state="done" if ticked else "open",
                           done_at=_hm(done_until) if ticked and done_until and done_until.date() == o.date() and (done_until.hour or done_until.minute) else "",
                           repeat=True, question=q, **look))
            continue
        if rec.get("status") == "done":
            da = local(rec.get("done_at")) if rec.get("done_at") else None
            if da and first <= da.date() <= last:
                sched = when(rec)
                at = _hm(sched) if sched and _has_time(rec.get("due") or rec.get("remind")) and sched.date() == da.date() else _hm(da)
                put(_entry("organizer", kind, key, title, da.date(), at, state="done", done_at=_hm(da), **look))
            continue
        if rec.get("status") != "open":
            continue
        w = when(rec)
        if w is None and q:
            # a line quick add was not sure about has no time of its own yet: it sits on the day of the earliest time it could mean
            # (today when no reading sets one), with its question, so the question is where the person looks
            ts = []
            for k in (rec.get("readings") or {}).get("kept") or []:
                for it in k.get("items") or []:
                    for f in ("remind", "due", "start"):
                        v = (it.get("args") or {}).get(f)
                        try:
                            ts.append(local(v)) if v else None
                        except Exception:
                            pass
            day = min(ts).date() if ts else today
            if first <= day <= last:
                put(_entry("organizer", kind, key, title, day, question=q, **look))
            continue
        if w is None:
            if rec.get("attention") == "now" and first <= today <= last:
                put(_entry("organizer", kind, key, title, today, question=q, **look))
            continue
        timed = _has_time(rec.get("due") or rec.get("remind"))
        if first <= w.date() <= last:
            put(_entry("organizer", kind, key, title, w.date(), _hm(w) if timed else "", question=q, **look))
        elif w.date() < today and first <= today <= last:
            put(_entry("organizer", kind, key, title, today, state="overdue", since=w.date().isoformat(), question=q, **look))
    for ev in events or []:
        ref = {"app": "colony", "id": ev.get("id") or "", "occurrence": ev.get("occurrence") or ""}
        if ev.get("id") in scheduled:
            continue
        s, e = str(ev.get("start") or ""), str(ev.get("end") or "")
        try:
            s_day = dt.date.fromisoformat(s[:10])
            e_day = dt.date.fromisoformat(e[:10]) if e else s_day
        except ValueError:
            continue
        all_day = bool(ev.get("all_day"))
        if all_day and e_day > s_day:
            e_day -= dt.timedelta(days=1)                       # an all-day event ends the day before its stated end
        e_day = max(s_day, e_day)
        day = max(s_day, first)
        while day <= min(e_day, last):
            timed = not all_day and day == s_day and len(s) >= 16
            put(_entry("colony", "event", "%s@%s" % (ev.get("id"), day.isoformat()), ev.get("title") or "Event", day,
                       time=s[11:16] if timed else "", end=e[11:16] if timed and e[:10] == s[:10] and len(e) >= 16 else "",
                       all_day=all_day or not timed, ref=ref, color=ev.get("colour") or None))
            day += dt.timedelta(days=1)
    for day in out.values():
        day.sort(key=lambda x: (x["time"] == "", x["time"], x["title"].lower()))
    return out


def day_label(day, today):
    delta = (day - today).days
    return {0: "Today", 1: "Tomorrow", -1: "Yesterday"}.get(delta) or day.strftime("%A")


def day_date_text(day):
    return "%s %d %s" % (day.strftime("%A"), day.day, day.strftime("%B"))


def greeting(hour):
    return "Good morning" if hour < 12 else "Good afternoon" if hour < 18 else "Good evening"


def day_view(entries, day, t):
    """One day: `rows` in the order they are drawn, and the same day said simply (`simple`). `t`: now (aware). Rows: {kind:'item', ...entry
    (+ until, late)}, {kind:'now'}, {kind:'free', text}. Things with no time follow in `anytime`."""
    today = t.date()
    mine = entries.get(day.isoformat(), [])
    timed = [e for e in mine if e["time"] and not e["all_day"]]
    anytime = [e for e in mine if not (e["time"] and not e["all_day"])]
    now_hm = _hm(t)
    is_today = day == today
    rows, nxt = [], None
    placed = False
    for e in timed:
        if is_today and not placed and e["time"] > now_hm:
            rows.append({"kind": "now", "time": now_hm, "time_text": clock_text(now_hm)})
            later_open = [x for x in timed if x["time"] > now_hm and x["state"] != "done"]
            if later_open:
                rows.append({"kind": "free", "text": "Free until " + later_open[0]["time_text"]})
            placed = True
        row = dict(e, kind="item", late=bool(is_today and e["state"] == "open" and e["time"] <= now_hm))
        if is_today and e["state"] == "open" and e["time"] > now_hm and nxt is None:
            mins = (dt.datetime.combine(day, dt.time(int(e["time"][:2]), int(e["time"][3:])), t.tzinfo) - t).total_seconds() / 60
            row["until"] = "in " + span_text(mins)
            row["until_words"] = "in " + span_words(mins)
            nxt = row
        rows.append(row)
    if is_today and not placed:
        rows.append({"kind": "now", "time": now_hm, "time_text": clock_text(now_hm)})
        rows.append({"kind": "free", "text": "Nothing more at a set time today" if timed else "Nothing at a set time today"})
    elif not timed and not is_today:
        rows.append({"kind": "free", "text": "Free" if not anytime else "Nothing at a set time"})
    anyrows = [dict(e, kind="item", late=False) for e in anytime]
    did = [{"id": e["id"], "text": said_back(e["title"], e["done_at_text"])} for e in mine if e["state"] == "done" and e["source"] == "organizer"]
    after = [x for x in rows if x.get("kind") == "item" and x["state"] != "done" and x is not nxt and not x["late"]]
    later = [{"id": x["id"], "title": x["title"], "time_text": x["time_text"], "source": x["source"]} for x in after] \
        + [{"id": x["id"], "title": x["title"], "time_text": "", "source": x["source"]} for x in anyrows if x["state"] != "done"]
    behind = [{"id": x["id"], "title": x["title"], "time_text": x["time_text"], "source": x["source"]}
              for x in rows if x.get("kind") == "item" and x.get("late")]
    return {"date": day.isoformat(), "label": day_label(day, today), "date_text": day_date_text(day), "is_today": is_today,
            "prev": (day - dt.timedelta(days=1)).isoformat(), "next": (day + dt.timedelta(days=1)).isoformat(),
            "now": {"time": now_hm, "time_text": clock_text(now_hm)}, "rows": rows, "anytime": anyrows,
            "simple": {"greeting": greeting(t.hour), "clock": "It's %s, %s" % (t.strftime("%A"), clock_text(now_hm)),
                       "next": ({"id": nxt["id"], "title": nxt["title"], "color": nxt["color"], "icon": nxt["icon"], "source": nxt["source"],
                                 "open": nxt["open"], "time_text": nxt["time_text"], "line": "At %s, %s" % (nxt["time_text"], nxt["until_words"]),
                                 "button": "I'm going" if nxt["source"] == "colony" else "Done"} if nxt else None),
                       "behind": behind, "later": later, "did": did,
                       "none": "" if nxt or later or did or behind else "Nothing is planned for today."}}


def pill(e):
    return {"id": e["id"], "title": e["title"], "time_text": e["time_text"], "color": e["color"], "icon": e["icon"], "state": e["state"],
            "source": e["source"], "question": bool(e["question"])}


def week_view(entries, day, t):
    today = t.date()
    monday = day - dt.timedelta(days=day.weekday())
    days = []
    for i in range(7):
        d = monday + dt.timedelta(days=i)
        mine = entries.get(d.isoformat(), [])
        days.append({"date": d.isoformat(), "day": d.day, "weekday": d.strftime("%a"), "today": d == today, "free": not mine,
                     "pills": [pill(e) for e in mine]})
    last = monday + dt.timedelta(days=6)
    text = ("%d - %d %s" % (monday.day, last.day, last.strftime("%B")) if monday.month == last.month
            else "%d %s - %d %s" % (monday.day, monday.strftime("%B"), last.day, last.strftime("%B")))
    return {"text": text, "days": days, "prev": (monday - dt.timedelta(days=7)).isoformat(), "next": (monday + dt.timedelta(days=7)).isoformat()}


def month_view(entries, day, t):
    today = t.date()
    first = day.replace(day=1)
    grid_start = first - dt.timedelta(days=first.weekday())
    nweeks = (first.weekday() + _cal.monthrange(first.year, first.month)[1] + 6) // 7
    cells = []
    for i in range(nweeks * 7):
        d = grid_start + dt.timedelta(days=i)
        mine = entries.get(d.isoformat(), [])
        colors = []
        for e in mine:
            if e["color"] not in colors:
                colors.append(e["color"])
        cells.append({"date": d.isoformat(), "day": d.day, "in_month": d.month == first.month, "today": d == today,
                      "count": len(mine), "colors": colors, "question": any(e["question"] for e in mine), "pills": [pill(e) for e in mine]})
    prev = (first - dt.timedelta(days=1)).replace(day=1)
    nxt = (first + dt.timedelta(days=32)).replace(day=1)
    return {"text": first.strftime("%B %Y"), "weekdays": ["M", "T", "W", "T", "F", "S", "S"], "cells": cells,
            "prev": prev.isoformat(), "next": nxt.isoformat()}


def year_view(entries, day, t):
    """Twelve small months, each day shaded by how full it is: a third of the year's busiest day each (picked, not grounded)."""
    today = t.date()
    busiest = max([len(v) for v in entries.values()] or [0])
    months = []
    for m in range(1, 13):
        first = dt.date(day.year, m, 1)
        days = []
        for n in range(_cal.monthrange(day.year, m)[1]):
            d = first + dt.timedelta(days=n)
            c = len(entries.get(d.isoformat(), []))
            level = 0 if not c else 1 if c * 3 <= busiest else 2 if c * 3 <= busiest * 2 else 3
            days.append({"date": d.isoformat(), "count": c, "level": level, "today": d == today,
                         "question": any(e["question"] for e in entries.get(d.isoformat(), []))})
        months.append({"month": first.isoformat(), "name": first.strftime("%b"), "offset": first.weekday(), "days": days,
                       "now": first.year == today.year and m == today.month})
    return {"text": str(day.year), "months": months, "busiest": busiest,
            "why": "shade: a third of the busiest day of the year each",
            "prev": dt.date(day.year - 1, 1, 1).isoformat(), "next": dt.date(day.year + 1, 1, 1).isoformat()}


def range_of(span, day):
    """(first, last) dates the span needs read."""
    if span == "day":
        return day, day
    if span == "week":
        mon = day - dt.timedelta(days=day.weekday())
        return mon, mon + dt.timedelta(days=6)
    if span == "month":
        first = day.replace(day=1)
        start = first - dt.timedelta(days=first.weekday())
        n = (first.weekday() + _cal.monthrange(first.year, first.month)[1] + 6) // 7
        return start, start + dt.timedelta(days=n * 7 - 1)
    return dt.date(day.year, 1, 1), dt.date(day.year, 12, 31)


def looks_of(mine):
    """The kinds' colours and symbols: the defaults, with those the person set (`mine`: {kind: {color, icon}})."""
    out = {k: tuple(v) for k, v in LOOKS.items()}
    for k, v in (mine or {}).items():
        if k in out and isinstance(v, dict):
            out[k] = (v.get("color") if v.get("color") in LOOK_COLORS else out[k][0], v.get("icon") if v.get("icon") in LOOK_ICONS else out[k][1])
    return out


def calendar_view(book, span, day, t, locked_on, local, when, events, lists, mode, events_note="", kind_looks=None):
    """The answer of `calendar` for a span around `day`."""
    _LOOKS[0] = looks_of(kind_looks)
    if span not in SPANS:
        raise ValueError("span is day, week, month or year")
    first, last = range_of(span, day)
    entries = entries_between(book, first, last, t.date(), locked_on, local, when, events, lists)
    out = {"span": span, "mode": mode, "modes": list(MODES), "today": t.date().isoformat(), "date": day.isoformat(), "note": events_note,
           "tabs": [{"id": s, "name": s.capitalize()} for s in SPANS],
           "looks": {k: {"color": v[0], "icon": v[1]} for k, v in _LOOKS[0].items()}}
    out[span] = {"day": day_view, "week": week_view, "month": month_view, "year": year_view}[span](entries, day, t)
    return out
