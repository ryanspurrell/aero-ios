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


QUIET = ("moved", "was_due")      # states of a row that only says where a thing went or was due: never next, late, counted or busy


def _quiet(e):
    return e["state"] in QUIET


def day_words(day, today):
    """A day said plainly in the middle of a sentence, by its name so it reads the same from any day: 'Friday' within a week of today,
    else '23 October'."""
    return day.strftime("%A") if abs((day - today).days) < 7 else "%d %s" % (day.day, day.strftime("%B"))


def _entry(source, kind, key, title, date, time="", end="", all_day=False, state="open", done_at="", since="", color=None, icon=None,
           repeat=False, ref=None, question=None, mark="", mark_text="", moved_to=None):
    c, i = _LOOKS[0][kind]
    return {"source": source, "type": kind, "id": key, "title": title, "date": date.isoformat(), "time": time, "time_text": clock_text(time),
            "end": end, "end_text": clock_text(end), "all_day": all_day, "state": state, "done_at": done_at, "done_at_text": clock_text(done_at),
            "since": since, "color": color or c, "icon": icon or i, "repeat": repeat, "open": ref or {"app": "organizer", "id": key},
            "question": question, "mark": mark, "mark_text": mark_text, "moved_to": moved_to}


def _hm(d):
    return d.strftime("%H:%M")


def _due_timed(rec):
    """Whether a task's due (else remind) time carries an hour: what the person gave where it was recorded (`due_timed`), else the old
    reading (midnight is how a date alone was kept)."""
    field = "due" if rec.get("due") else "remind"
    flag = rec.get(field + "_timed")
    return flag if isinstance(flag, bool) else _has_time(rec.get(field))


def _has_time(text):
    """A stored time carries an hour; midnight is how a date alone is kept, so it is read as no time."""
    t = str(text or "").strip()
    return len(t) > 10 and t[11:16] != "00:00"


def _one_row_each(day):
    """A thing is on a day once. Where one task has two rows on one day (done and then reopened, or an open place and a done one), the open
    row stays and says it was done earlier; else the done row stays; a quiet row gives way to either. Nothing is dropped from another day."""
    rank = lambda e: 2 if e["state"] not in ("done",) + QUIET else 1 if e["state"] == "done" else 0
    keep, out = {}, []
    for e in day:
        k = (e["source"], e["id"]) if e["source"] == "organizer" else None
        if k is None or k not in keep:
            if k:
                keep[k] = e
            out.append(e)
            continue
        old = keep[k]
        win, lose = (e, old) if rank(e) > rank(old) else (old, e)
        if lose["state"] == "moved" and win["state"] not in ("done",) + QUIET:
            win["mark_text"] = lose["mark_text"]               # behind from the new day and due here: one row says both
        if lose["state"] == "done" and win["state"] not in ("done",) + QUIET:
            win["mark_text"] = " \u00b7 ".join(x for x in (win["mark_text"], "Done earlier, then reopened") if x)
        if win is e:
            out[out.index(old)] = e
            keep[k] = e
    return out


def entries_between(book, first, last, today, locked_on, local, when, events, lists):
    """(A thing's colour is data its owner keeps and every surface draws as given: a list's colour, a kind's colour the person set (or
    the default above), a calendar event's own calendar colour from Colony, a hex value. Nothing draws a colour of its own.)
    Every thing on the days first..last (dates, inclusive) as {date: [entry]}: Organizer's tasks that have a time or a date (a repeat on
    each day it falls; what was done on the day it was done; an open one from before, on today only, as 'from before'), and Colony's
    events. A task not marked Open (Locked, or made before the marker) only while Locked mode is on: unchecked is private. A task set aside is not
    shown. A task that is a calendar event's time is shown once, as the task. `lists`: {project id: record}.
    The day's requirements (rebuild__bottom_up_organizer.md, "Answers so far"; DayRequirements.lean `reqOn`, which this matches by tests,
    not by proof): an open task put off to a day not yet past is on its new day and time as normal, marked "Moved from <old day>", and on
    its old day (when that is another day) as a quiet row, state "moved", "Moved to <day time>", `moved_to` naming the new place; a done
    task is on the day it was done, whatever deferral it carries; a done task due on another day is also on that day as a quiet row, state
    "was_due", "Done later, on <day>", and its done row says "Was due <day>". Within a time no order is made: the entries stay as the book
    gave them, and the viewer's own order or reading direction is the drawing's."""
    out = {}
    order = []                                          # every entry in the order made; the cap is applied to what is left after rows are merged

    def put(entry):
        out.setdefault(entry["date"], []).append(entry)
        order.append(entry)

    start = dt.datetime.combine(first, dt.time(), local("2000-01-01").tzinfo)
    stop = dt.datetime.combine(last, dt.time(23, 59, 59), start.tzinfo)
    scheduled = set()
    for oid, item in book.now.items():
        rec = item["rec"]
        if rec.get("type") == "task" and rec.get("status") == "open" and rec.get("event") and not (rec.get("deferred") or {}).get("until"):
            scheduled.add(rec["event"])       # a task put off no longer stands for its event: Colony's is still where it was
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
        until = local(d["until"]) if d.get("until") else None
        held = until if rec.get("repeat") else None      # a repeating task put off: its open times before the new time wait
        ahead = bool(until) and rec.get("status") == "open" and not rec.get("repeat")
        kind = "buy" if rec.get("type") == "buy" else "repeat" if rec.get("repeat") else "task"
        q = question_of(oid, rec)
        key = oid[:8]
        if rec.get("repeat") and rec.get("start"):
            try:
                rule = rrulestr(rec["repeat"], dtstart=local(rec["start"]))
                times = rule.between(start, stop, inc=True)[:ITEMS_MAX]
            except (ValueError, TypeError):
                rule, times = None, []
            done_until = local(rec.get("done_until")) if rec.get("done_until") else None
            rep_timed = rec.get("start_timed") is True          # an hour given as 00:00 is a time, not a date alone
            for o in times:
                ticked = bool(done_until and o <= done_until)
                if (o.date() < today or (held and o < held)) and not ticked:
                    continue                                     # a past time nobody ticked: not claimed either way
                put(_entry("organizer", kind, key, title, o.date(), _hm(o) if (rep_timed or o.hour or o.minute) else "", state="done" if ticked else "open",
                           done_at=_hm(done_until) if ticked and done_until and done_until.date() == o.date() and (done_until.hour or done_until.minute) else "",
                           repeat=True, question=q, **look))
            if held and rule is not None and held.date() >= today and first <= held.date() <= last and not rule.between(held, held, inc=True):
                # put off to a time the schedule does not have: it is there at that time (the times before it wait, the next one is as scheduled)
                put(_entry("organizer", kind, key, title, held.date(), _hm(held) if d.get("timed", True) else "", repeat=True, question=q,
                           mark="moved_from", mark_text="Moved", **look))
            continue
        # done is a dated observation that accumulates (Aryn, 2026-10-17): every one is on its own day, faded; a task never loses one
        obs = {}
        for x in rec.get("done_ats") or ([rec["done_at"]] if rec.get("done_at") else []):
            o = local(x)
            if o and (o.date() not in obs or o > obs[o.date()]):
                obs[o.date()] = o
        if obs:
            sched = when(rec)
            timed_due = _due_timed(rec)
            earliest = obs[min(obs)]
            for n, (day, da) in enumerate(sorted(obs.items())):
                if first <= day <= last:
                    other = bool(sched) and sched.date() != day            # due one day, done another
                    at = _hm(sched) if sched and timed_due and sched.date() == day else _hm(da)
                    was = ("%s %s" % ("Was due" if sched < da else "Due", day_words(sched.date(), today))) if other and n == 0 else "Done again" if n else ""
                    put(_entry("organizer", kind, key, title, day, at, state="done", done_at=_hm(da), mark="due_then_done" if other and n == 0 else "",
                               mark_text=was, **look))
            if sched and sched.date() not in obs and first <= sched.date() <= last:
                put(_entry("organizer", kind, key, title, sched.date(), _hm(sched) if timed_due else "", state="was_due", mark="due_then_done",
                           mark_text="Done %s, on %s" % ("later" if sched < earliest else "earlier", day_words(earliest.date(), today)), **look))
            if rec.get("status") == "done":
                continue
        if rec.get("status") != "open":
            continue
        w = when(rec)
        if ahead:
            # put off to a day not yet past: on the new day and time as normal, marked; the old day says where it went, quietly
            nd = until.date()
            new_timed = _has_time(d["until"])
            old_timed = _due_timed(rec)
            if w is None:
                moved_from = "Moved"
            elif w.date() != nd:
                moved_from = "Moved from " + day_words(w.date(), today)
            else:
                moved_from = "Moved from " + clock_text(_hm(w)) if old_timed else "Moved"
            new_timed = d["timed"] if "timed" in d else new_timed
            if first <= nd <= last:
                put(_entry("organizer", kind, key, title, nd, _hm(until) if new_timed else "", question=q, mark="moved_from",
                           mark_text=moved_from, **look))
            if nd < today and first <= today <= last:
                # the new day has passed and it is still open: behind, from where it was moved to (not from where it was first due)
                put(_entry("organizer", kind, key, title, today, state="overdue", since=nd.isoformat(), mark="moved_from", mark_text=moved_from,
                           question=q, **look))
            if w is not None and w.date() != nd and first <= w.date() <= last:
                where = day_words(nd, today) + (" " + clock_text(_hm(until)) if new_timed else "")
                # the new day has passed and it is still open: the due day still shows it as due, since it may have been done and not marked
                said = ("%s %s; moved to %s" % ("Was due" if w.date() < today else "Due", day_words(w.date(), today), where)) if nd < today \
                    else "Moved to " + where
                put(_entry("organizer", kind, key, title, w.date(), _hm(w) if old_timed else "", state="moved", mark="moved_to",
                           mark_text=said,
                           moved_to={"date": nd.isoformat(), "time": _hm(until) if new_timed else "", "text": where}, **look))
            continue
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
        timed = _due_timed(rec)
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
    for date, day in list(out.items()):
        out[date] = _one_row_each(day)
    kept = {id(e) for day in out.values() for e in day}
    cap = [ITEMS_MAX, ITEMS_MAX]                        # the things, and apart from them the quiet rows (they must not crowd a thing out)
    out = {}
    for e in order:
        i = 1 if _quiet(e) else 0
        if id(e) in kept and cap[i] > 0:
            out.setdefault(e["date"], []).append(e)
            cap[i] -= 1
    for day in out.values():
        day.sort(key=lambda x: (x["time"] == "", x["time"]))      # by time only: python's sort is stable, so a tie stays as the book gave it
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
    rows, nxt, tied = [], None, []
    placed = False
    tie = None                                   # the time of the next one: everything at that time is next together, none before another
    for e in timed:
        if is_today and not placed and e["time"] > now_hm:
            rows.append({"kind": "now", "time": now_hm, "time_text": clock_text(now_hm)})
            later_open = [x for x in timed if x["time"] > now_hm and x["state"] not in ("done",) + QUIET]
            if later_open:
                rows.append({"kind": "free", "text": "Free until " + later_open[0]["time_text"]})
            placed = True
        row = dict(e, kind="item", late=bool(is_today and e["state"] == "open" and e["time"] <= now_hm))
        if is_today and e["state"] == "open" and e["time"] > now_hm and (nxt is None or e["time"] == tie):
            mins = (dt.datetime.combine(day, dt.time(int(e["time"][:2]), int(e["time"][3:])), t.tzinfo) - t).total_seconds() / 60
            row["until"] = "in " + span_text(mins)
            row["until_words"] = "in " + span_words(mins)
            if nxt is None:
                nxt, tie = row, e["time"]
            else:
                tied.append(row)
        rows.append(row)
    if is_today and not placed:
        rows.append({"kind": "now", "time": now_hm, "time_text": clock_text(now_hm)})
        rows.append({"kind": "free", "text": "Nothing more at a set time today" if timed else "Nothing at a set time today"})
    elif not timed and not is_today:
        rows.append({"kind": "free", "text": "Free" if not anytime else "Nothing at a set time"})
    anyrows = [dict(e, kind="item", late=False) for e in anytime]
    did = [{"id": e["id"], "text": said_back(e["title"], e["done_at_text"])} for e in mine if e["state"] == "done" and e["source"] == "organizer"]
    nexts = ([nxt] + tied) if nxt else []
    after = [x for x in rows if x.get("kind") == "item" and x["state"] != "done" and x["state"] not in QUIET and not any(x is n for n in nexts)
             and not x["late"]]
    later = [{"id": x["id"], "title": x["title"], "time_text": x["time_text"], "source": x["source"]} for x in after] \
        + [{"id": x["id"], "title": x["title"], "time_text": "", "source": x["source"]} for x in anyrows if x["state"] != "done" and x["state"] not in QUIET]
    behind = [{"id": x["id"], "title": x["title"], "time_text": x["time_text"], "source": x["source"]}
              for x in rows if x.get("kind") == "item" and x.get("late")]
    return {"date": day.isoformat(), "label": day_label(day, today), "date_text": day_date_text(day), "is_today": is_today,
            "prev": (day - dt.timedelta(days=1)).isoformat(), "next": (day + dt.timedelta(days=1)).isoformat(),
            "now": {"time": now_hm, "time_text": clock_text(now_hm)}, "rows": rows, "anytime": anyrows,
            "simple": {"greeting": greeting(t.hour), "clock": "It's %s, %s" % (t.strftime("%A"), clock_text(now_hm)),
                       "next": ({"id": nxt["id"], "title": nxt["title"], "color": nxt["color"], "icon": nxt["icon"], "source": nxt["source"],
                                 "open": nxt["open"], "time_text": nxt["time_text"], "line": "At %s, %s" % (nxt["time_text"], nxt["until_words"]),
                                 "button": "I'm going" if nxt["source"] == "colony" else "Done",
                                 # others at the same time: none is first. `next` is the first as the book gave them, for a screen
                                 # that draws one; a screen that can order them (the viewer's own order, their reading direction) uses `nexts`
                                 "also": [{"id": x["id"], "title": x["title"], "source": x["source"]} for x in tied]} if nxt else None),
                       "nexts": [{"id": n["id"], "title": n["title"], "color": n["color"], "icon": n["icon"], "source": n["source"],
                                  "open": n["open"], "time_text": n["time_text"], "line": "At %s, %s" % (n["time_text"], n["until_words"]),
                                  "button": "I'm going" if n["source"] == "colony" else "Done"} for n in nexts],
                       "behind": behind, "later": later, "did": did,
                       "none": "" if nxt or later or did or behind else "Nothing is planned for today."}}


def pill(e):
    return {"id": e["id"], "title": e["title"], "time_text": e["time_text"], "color": e["color"], "icon": e["icon"], "state": e["state"],
            "source": e["source"], "question": bool(e["question"]), "mark_text": e["mark_text"]}


def week_view(entries, day, t):
    today = t.date()
    monday = day - dt.timedelta(days=day.weekday())
    days = []
    for i in range(7):
        d = monday + dt.timedelta(days=i)
        mine = entries.get(d.isoformat(), [])
        days.append({"date": d.isoformat(), "day": d.day, "weekday": d.strftime("%a"), "today": d == today, "free": not [e for e in mine if not _quiet(e)],
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
        for e in (x for x in mine if not _quiet(x)):
            if e["color"] not in colors:
                colors.append(e["color"])
        cells.append({"date": d.isoformat(), "day": d.day, "in_month": d.month == first.month, "today": d == today,
                      "count": len([e for e in mine if not _quiet(e)]), "colors": colors, "question": any(e["question"] for e in mine), "pills": [pill(e) for e in mine]})
    prev = (first - dt.timedelta(days=1)).replace(day=1)
    nxt = (first + dt.timedelta(days=32)).replace(day=1)
    return {"text": first.strftime("%B %Y"), "weekdays": ["M", "T", "W", "T", "F", "S", "S"], "cells": cells,
            "prev": prev.isoformat(), "next": nxt.isoformat()}


def year_view(entries, day, t):
    """Twelve small months, each day shaded by how full it is: a third of the year's busiest day each (picked, not grounded)."""
    today = t.date()
    busiest = max([len([e for e in v if not _quiet(e)]) for v in entries.values()] or [0])
    months = []
    for m in range(1, 13):
        first = dt.date(day.year, m, 1)
        days = []
        for n in range(_cal.monthrange(day.year, m)[1]):
            d = first + dt.timedelta(days=n)
            c = len([e for e in entries.get(d.isoformat(), []) if not _quiet(e)])
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
