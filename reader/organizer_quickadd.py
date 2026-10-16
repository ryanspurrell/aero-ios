"""Quick add: one line of words, typed or from the phone's own speech-to-text, read into an Organizer item.
No model is called here and none can be: the module imports no network, process or model code
(test_quickadd.py fails if that changes).

The simplest model: Fingus Core's reader (fingus_core_reader.py, a Lark Earley grammar) says every way the date, time and
repeat words of the line can be read; this layer decides what to do with them. Where the line has one reading and
nothing in doubt, the item is made. Where it has several (an hour with no am or pm, "next friday", 10/12), or a
reading in doubt (a time already gone, two days), nothing is guessed: the line is kept whole as a plain task, what was
understood is shown beside it, and every reading is kept with how likely it is, likeliest first, for the person to
pick or fix ("a suggested change is the participant's to accept", core/design__core_principles_2026-10-09.md; the owner,
2026-10-15: "fingus should ask. if it's ambiguous", "shouldn't pretend to know. if user doesn't answer then we can store
the options", "when i say always a way, i mean that data is stored with probabilities"). The readings are kept on the
item as not answered (not answered is not declined).

Sources (the rules follow these; they are not a new scheme):
- The grammar, and why it replaced the list of patterns this module used to hold: fingus_core_reader.py and the
  decision log, 2026-10-15.
- Dates are calendar arithmetic; a repeat's first time is worked out with python-dateutil's rrule, the library Organizer
  already uses for repeats (dateutil.readthedocs.io).
- A repeat is an RFC 5545 RRULE (rfc-editor.org/rfc/rfc5545, section 3.3.10), as Organizer keeps it.
- A date is shown as ISO 8601 (YYYY-MM-DD), a time as HH:MM, in the item; the words the person
  sees say them in their own clock.
- "tonight" and "today" follow the person's waking day when the caller says when they woke
  (design__moments_inside_your_day_outside_2026-10-14.md; Core's check-ins take a waking day as
  16 hours from waking, fingus_core_checkins.py); with no wake time they are plain local time, said
  so in every answer.
- A time that was not said is not made up: a repeat with no hour has no hour (the owner, 2026-10-15).

Numbers here carry their why. Each is "picked, not grounded" until a measurement grounds it.
"""
import datetime as dt
import re

from dateutil.rrule import rrulestr

import fingus_core_reader as GR              # Fingus Core's reader: the grammar for dates, times and repeats (core/design__one_reader_2026-10-15.md)

LATE_NIGHT = (4, "picked, not grounded: before 4 AM, with no wake time known, 'today', 'tonight' and 'tomorrow' could mean "
                 "the day just ended or the one starting")
WAKING_HOURS = (16, "Core's check-ins take a waking day as 16 hours from waking (fingus_core_checkins.py)")
# How likely each kept reading is. Nothing has been learned from her answers yet, so the shares are equal; a word in the
# line that hints at one reading (the owner, 2026-10-15, on "wake up early tomorrow at 6": "in this case i'd assume user
# means 6 am") puts it first with the larger share.
HINTED_SHARE = (0.7, "picked, not grounded: a hinted reading is given 0.7 and the others share the rest; the owner named the "
                     "hint (2026-10-15, 'early' with a bare hour means AM) but not the number")
EQUAL_SHARES = "picked, not grounded: equal shares, nothing has been learned from her answers yet"
HINTS = {"early": "AM"}
# something already done, told as such ("called the bank this morning"): not a reminder. Making these into entries of what happened is
# not built yet (aero/design__what_happened_2026-10-15.md); here they are only never made into a reminder.
PAST_IRREGULAR = {"saw", "had", "went", "got", "bought", "paid", "ran", "slept", "met", "made", "took", "gave", "did", "was", "were",
                  "said", "came", "found", "left", "lost", "sent", "spent", "wrote", "woke", "ate", "drank", "heard", "felt", "knew"}
PAST_MARKERS = re.compile(r"\b(ago|last night|earlier today|this morning|yesterday|last (?:week|weekend|month|year|monday|tuesday|wednesday|thursday|friday|saturday|sunday))\b")
READ_STATES = ("not answered", "answered", "declined")      # not answered is not declined
KEEP_READINGS = 8                                           # picked, not grounded: at most this many readings are kept

# Learned from her answers (the owner, 2026-10-15, "learning the likeliest reading per person, shown first with its why, still asking
# unless she switches a kind of question off"). A question has a kind (what the marks say is in doubt), and each reading in it
# a choice (AM or PM; sooner or later; the whole weekend or a day). The service counts, for one person, which choice was picked
# for each kind of question, and passes the counts in as `learned` = {"counts": {kind: {choice: n}}, "off": [kinds]}; this module
# stays a pure reader. Prior art for the smoothing: Laplace's rule of succession (1814), (n + 1) / (N + 2) for two choices, which
# is a Beta(1, 1) prior (a Dirichlet(1, ...) prior for K choices); and, so that "9 AM or PM" can learn by the hour yet not start
# from nothing at every hour, a hierarchical Dirichlet prior (MacKay and Peto 1995, "A hierarchical Dirichlet language model"):
# an hour's estimate is (n + K * the estimate for any hour) / (N + K), and "any hour" is (n + K * equal shares) / (N + K). The
# prior's weight is K, the number of choices, which is Laplace's own, so no weight or threshold here is picked.
ASK_KINDS = ("ampm", "next", "sameday", "weekend", "span", "event", "slash", "pastyear", "late")
LEARNED_BASIS = ("learned from your answers: (times you picked it + K x the estimate one step wider) / (times you answered + K), "
                 "K the number of kinds of reading in the question; one step wider is the same kind of question at any hour, then equal "
                 "shares (Laplace's rule of succession, 1814; a hierarchical Dirichlet prior, MacKay and Peto 1995)")

# Organizer's own words, registered with the reader: what a line that starts "remind me" or "buy", or ends "to the shopping list", is, and
# the times tied to something she does (what each could mean is this part's to say: it knows meals, work and bed as her day).
LEAD_REMIND = re.compile(r"^(?:please\s+)?remind\s+me(?:\s+(?:to|about|that))?\b", re.I)
LEAD_BUY = re.compile(r"^(?:please\s+)?(?:buy|purchase|order)\b", re.I)
TAIL_LIST = re.compile(r"\b(?:to\s+)?(?:my\s+|the\s+)?(?:shopping|grocery|buy)\s+list\s*[.!]?$", re.I)
LEAD_ADD = re.compile(r"^(?:please\s+)?add\b", re.I)
EVENT_WORDS = r"(after (eating|breakfast|lunch|dinner|supper|work|school|class|the gym|gym|waking up|every run|a run|the meeting|my run)|before (bed|bedtime|sleep|leaving|i go to sleep|i leave|the meeting|going to bed|work)|with (breakfast|lunch|dinner)|when i (wake up|get up|get home|got home|get to the office|get to work|leave work|leave home|leave the office|arrive)|when \w+ (lands|arrives|gets home|gets here))(?![a-z])"
EVENT_TABLE = {"after eating": [("After breakfast", "morning"), ("After lunch", "afternoon"), ("After dinner", "evening"),
                                ("After every meal", None)],
               "after breakfast": [("After breakfast", "morning")], "after lunch": [("After lunch", "afternoon")],
               "after dinner": [("After dinner", "evening")], "after supper": [("After dinner", "evening")],
               "after work": [("After work", "evening")], "after school": [("After school", "afternoon")],
               "before bed": [("Before bed", "night")], "before bedtime": [("Before bed", "night")], "before sleep": [("Before bed", "night")],
               "when i wake up": [("When you wake up", "morning")], "when i get up": [("When you wake up", "morning")]}
GR.register("organizer", leads=[("remind", LEAD_REMIND), ("buy", LEAD_BUY)], tails=[("buy", TAIL_LIST, LEAD_ADD)],
            events={"pattern": EVENT_WORDS, "table": EVENT_TABLE})

WEEKDAYS = GR.WEEKDAYS
# what it reads, in words for the screen (a short list, not a promise of more)
READS = ["a date: today, tonight, tomorrow, next week, a weekday, oct 12, 2026-11-03, in 2 days",
         "a time: 9pm, 14:30, at 5 with tonight or evening, noon",
         "a repeat: every day, every tuesday, mon wed fri, every other saturday, weekdays, every 2 weeks, monthly, "
         "the 5th and 20th of each month",
         "a thing to buy: buy ..., add ... to the shopping list", "remind me to ...", "! to flag, #name for a list"]


def _label(d, today, tonight=False):
    k = (d - today).days
    if k == 0:
        return "tonight" if tonight else "today"
    return "tomorrow" if k == 1 else d.strftime("%A %-d %b") if 1 < k < 14 else d.strftime("%a %-d %b" + ("" if d.year == today.year else " %Y"))


def _cap(text):
    """Sentence case for what Fingus writes (wording_conventions.md): the first letter, and the names of days and months. Her own
    words, quoted as she typed them, are never passed through this."""
    text = re.sub(r"\b(monday|tuesday|wednesday|thursday|friday|saturday|sunday|january|february|march|april|june|july|august|september|"
                  r"october|november|december)\b", lambda m: m.group(1).capitalize(), str(text))
    return text[:1].upper() + text[1:]


def _clock(h, m):
    return "%d:%02d %s" % ((h % 12) or 12, m, "AM" if h < 12 else "PM")


class Reader:
    """The line, with each part taken out as it is read (the flag, the list name and the quotes; the grammar reads the rest)."""

    def __init__(self, text):
        self.s = " " + text + " "
        self.found = []                                  # (position, words) of what was taken

    def cut(self, pat, ok=None):
        for m in re.finditer(pat, self.s, re.I):
            if ok is None or ok(m):
                words = m.group(0).strip()
                self.found.append((m.start(), words))
                self.s = self.s[:m.start()] + " " + self.s[m.end():]
                return m, words
        return None, None

    def peek(self, pat, ok=None):
        return [m for m in re.finditer(pat, self.s, re.I) if ok is None or ok(m)]


def _repeat_text(rp):
    """A repeat as Organizer's words or RRULE (rule_of reads it): the grammar's repeat, in the form the earlier reader gave."""
    f, n, days = rp["freq"], rp["interval"], rp["days"]
    abbr = ["MO", "TU", "WE", "TH", "FR", "SA", "SU"]
    if f == "DAILY":
        return "daily" if n == 1 else "FREQ=DAILY;INTERVAL=%d" % n
    if f == "WEEKLY":
        if days and n == 1:
            if days == [0, 1, 2, 3, 4, 5, 6]:
                return "daily"
            if days == [0, 1, 2, 3, 4]:
                return "weekdays"
            if days == [5, 6]:
                return "weekends"
            return "every " + ", ".join(WEEKDAYS[d].lower() for d in days)
        if days:
            return "FREQ=WEEKLY;INTERVAL=%d;BYDAY=%s" % (n, ",".join(abbr[d] for d in days))
        return "weekly" if n == 1 else "FREQ=WEEKLY;INTERVAL=%d" % n
    if f == "MONTHLY":
        extra = ";INTERVAL=%d" % n if n != 1 else ""
        if rp["mdays"]:
            return "FREQ=MONTHLY%s;BYMONTHDAY=%s" % (extra, ",".join(str(d) for d in rp["mdays"]))
        if rp["nth"]:
            return "FREQ=MONTHLY%s;BYDAY=%d%s" % (extra, rp["nth"][0], abbr[rp["nth"][1]])
        return "monthly" if n == 1 else "FREQ=MONTHLY;INTERVAL=%d" % n
    return "yearly" if n == 1 else "FREQ=YEARLY;INTERVAL=%d" % n


def _spec(r, now, today):
    """(day, time, repeat words) of one schedule. A repeat starts today, or tomorrow once its hour has passed; with no hour
    said it has none (the earlier reader started every such repeat at 09:00, which nobody said)."""
    rp = r["repeat"]
    if not rp:
        return r["date"], r["time"], None
    day, time = today, r["time"]
    if time and time <= (now.hour, now.minute):
        day = today + dt.timedelta(days=1)
    return day, time, _repeat_text(rp)


def kind_chain(kind):
    """The kind of question and the wider kind it is counted under too: ["ampm+next", "ampm:9+next"] (wider first); one kind
    when there is no detail to widen."""
    wide = re.sub(r":\d+", "", kind)
    return [wide] if wide == kind else [wide, kind]


def _tags(live):
    """(kind, [choice for each reading]) for readings the person is choosing between, or None when nothing here can be learned
    (one reading, or a doubt that is not a choice, like 'a reminder on each')."""
    if len(live) < 2:
        return None
    marks = [m for _s, ms in live for m in ms]
    kinds = sorted({m[0] for m in marks} & set(ASK_KINDS))
    if not kinds:
        return None
    dates = sorted({(rd[0][0].get("date") or dt.date.min) for rd in live if not rd[0][0].get("repeat")})
    key, ch = [], [[] for _ in live]
    for k in kinds:
        name = k
        if k == "ampm":
            hours = {m[2] or 12 for m in marks if m[0] == "ampm"}
            name = "ampm:%d" % hours.pop() if len(hours) == 1 else "ampm"
        key.append(name)
        for i, (scheds, _m) in enumerate(live):
            if k == "ampm":
                t = next((s["time"] for s in scheds if s.get("time")), None)
                ch[i].append("AM" if t and t[0] < 12 else "PM")
            elif k in ("weekend", "span"):
                ch[i].append("whole" if any(s.get("until") for s in scheds) else "a day")
            elif k == "event":                          # a time tied to something she does: which part of the day it was taken as
                ch[i].append(str(scheds[0].get("part_of_day") or scheds[0].get("event_text") or "event"))
            elif scheds[0].get("repeat"):               # "oct 3" past: the 3rd of every month, against a date
                ch[i].append("repeat")
            else:
                ch[i].append("sooner" if (scheds[0].get("date") or dt.date.min) == dates[0] else "later")
    choices = ["+".join(c) for c in ch]
    return ("+".join(key), choices) if len(set(choices)) > 1 else None


def _learn(tags, learned):
    """Each reading's likelihood and why from the person's counts, or None when none of their answers is of this kind."""
    if not tags or not learned:
        return None
    kind, choices = tags
    names = sorted(set(choices))
    K = len(names)
    p = {c: 1 / K for c in names}
    used = None
    for key in kind_chain(kind):
        counts = (learned.get("counts") or {}).get(key) or {}
        n = {c: int(counts.get(c, 0)) for c in names}
        N = sum(n.values())
        if N:
            p = {c: (n[c] + K * p[c]) / (N + K) for c in names}
            used = (n, N, key)
    if not used:
        return None
    n, N, key = used
    share = {c: choices.count(c) for c in names}
    probs = [round(p[c] / share[c], 3) for c in choices]
    where = " at any hour" if key != kind else ""
    whys = ["you picked this %d of %d times%s%s" % (n[c], N, where, ", shared among the %d readings of that kind" % share[c] if share[c] > 1 else "")
            for c in choices]
    return {"probs": probs, "whys": whys, "basis": LEARNED_BASIS}


def understand(line, now=None, woke=None, lists=(), rule_of=None, where=None, choose=None, learned=None):
    """Read `line` (see `_understand`), then put what it made where the person typed it: `where` is the screen's own place
    for a new item, {project, section, attention, urgent, routine, today}: the list it was typed in, its section, a view of
    attention, flagged, a routine (a repeat, daily if none was read), a view of today (due today if no day was read)."""
    out = _understand(line, now, woke, lists, rule_of, choose, learned)
    return _place(out, where or {}, (now or dt.datetime.now().astimezone()).date())


def _place(out, where, today):
    settled = not out["plain"] or not (out["unsure"] or out.get("readings"))
    plain_no_date = out["plain"] and not out["unsure"] and not out.get("readings")

    def put(args):
        if where.get("project") and "project" not in args:
            args["project"] = str(where["project"])
        if where.get("section") and "section" not in args:
            args["section"] = str(where["section"])[:60]
        if where.get("attention") in ("now", "next", "later") and "attention" not in args:
            args["attention"] = where["attention"]
        if where.get("urgent"):
            args["urgent"] = True
        if (settled or plain_no_date) and not (out["plain"] and out["unsure"]):
            if where.get("routine") and "repeat" not in args:
                args["repeat"], args["start"] = "daily", today.isoformat()
            elif where.get("today") and not any(k in args for k in ("due", "repeat", "timing")):
                args["due"] = today.isoformat()
    if not where:
        return out
    put(out["args"])
    for it in out.get("items") or []:
        put(it["args"])
    for sg in out.get("suggestions") or []:
        put(sg["args"])
        for it in sg.get("items") or []:
            put(it["args"])
    for k in (out.get("readings") or {}).get("kept") or []:
        for it in k["items"]:
            put(it["args"])
    return out


def _past_event(line):
    """Whether the line tells something that already happened ("saw jo at the park yesterday", "paid rent on the 1st")."""
    words = re.findall(r"[a-z']+", line.lower())
    ed = lambda w: len(w) >= 5 and w.endswith("ed") and not w.endswith("eed")
    return bool(words) and (any(w in PAST_IRREGULAR for w in words)
                            or any(ed(w) for w in words[:4]) and bool(PAST_MARKERS.search(line.lower())))


def _happened(line, said, readings, today):
    """What the form offers for a line told as something that already happened (core/design__what_happened_2026-10-15.md): the
    words as said and what time they are about, from the reader's readings that are not in the future, with how sure. Nothing is
    kept here; the person's choice in the form keeps it (Core's Life logs). {text, about, about_words}."""
    days, time, part, stretch = set(), set(), set(), False
    for scheds, _marks in readings:
        s0 = scheds[0] if scheds else {}
        d = s0.get("date")
        if d and d <= today:
            days.add(d)
            if s0.get("until") and s0["until"] <= today:       # a stretch ("last week", "a few days ago"): kept as the range it is
                days.add(s0["until"])
                stretch = True
            time.add(s0.get("time"))
            part.add(s0.get("part_of_day"))
    about = None
    if days:
        lo, hi = min(days), max(days)
        about = {"from": lo.isoformat(), "said": said,
                 "sure": "read from '%s'" % said if len(days) == 1 else
                         "'%s' is a stretch of time, not one day" % said if stretch and len(readings) == 1 else
                         "'%s' could be any of %d days" % (said, len(days))}
        if hi != lo:
            about["to"] = hi.isoformat()
        if len(days) == 1 and len(time) == 1 and None not in time:
            about["time"] = "%02d:%02d" % next(iter(time))
        if len(days) == 1 and len(part) == 1 and None not in part:
            about["part"] = next(iter(part))
        words = lo.strftime("%a %-d %b" + ("" if lo.year == today.year else " %Y")) + (
            "" if lo == hi else " to " + hi.strftime("%a %-d %b" + ("" if hi.year == today.year else " %Y")))
    else:
        words = ""
    return {"text": line, "about": about, "about_words": words}


def _understand(line, now=None, woke=None, lists=(), rule_of=None, choose=None, learned=None):
    """Read `line`. `now`: an aware local datetime. `woke`: when the person last woke (aware), if known.
    `lists`: [{id, title}] for #name. `rule_of`: Organizer's repeat reader (words to RRULE).
    Returns {line, plain, args, type, shown_as, says, understood, unsure, suggestions, reads, day, items, readings}.
    `items`: every item the line makes (one, or more when it names several schedules); `args` and `type` are the first.
    `readings`: None when the line is settled; else what is kept on the item: every reading, with how likely each is."""
    now = (now or dt.datetime.now().astimezone()).replace(second=0, microsecond=0)
    line = str(line or "").strip()
    out = {"line": line, "plain": True, "type": "task", "shown_as": "task", "args": {"title": line, "text": line},
           "says": "", "understood": [], "unsure": [], "suggestions": [], "reads": READS, "day": None, "items": [],
           "readings": None}
    if not line:
        out["unsure"].append({"what": "line", "said": "", "why": "nothing was typed"})
        return out
    # the person's day: a waking day, else plain local time (said which)
    if woke and woke <= now < woke + dt.timedelta(hours=WAKING_HOURS[0]):
        today, day_basis = woke.date(), "your waking day since %s" % _clock(woke.hour, woke.minute)
    else:
        today, day_basis = now.date(), "plain local time"
    out["day"] = day_basis
    late_night = day_basis == "plain local time" and now.hour < LATE_NIGHT[0]

    kept = []
    r = Reader(re.sub(r'"([^"]*)"', lambda m: (kept.append(m.group(1)) or "\u0001%d\u0001" % (len(kept) - 1)), line))
    got, unsure = [], []                                # understood parts; things it was not sure of

    def part(what, shown, words, why):
        got.append({"what": what, "shown": shown, "from": words, "why": why})

    def doubt(what, words, why):
        unsure.append({"what": what, "said": words, "why": why})

    urgent = bool(r.cut(r"(?<=\s)!{1,3}(?=\s)")[0])
    if urgent:
        part("flag", "Flagged", "!", "a ! flags it")
    project = None
    tag, words = r.cut(r"(?<=\s)#([^\s#]+)(?=\s)")
    if tag and lists:
        key = re.sub(r"[^a-z0-9]", "", tag.group(1).lower())
        norm = lambda x: re.sub(r"[^a-z0-9]", "", str(x or "").lower())
        hit = key and (next((l for l in lists if norm(l.get("title")).startswith(key)), None)
                       or next((l for l in lists if key in norm(l.get("title"))), None))
        if hit:
            project = hit["id"]
            part("list", hit.get("title") or "List", words, "#name puts it in the list that starts with that name")
        else:
            r.s = r.s[:tag.start()] + " " + words + " " + r.s[tag.start() + 1:]   # not a list: stays in the words
            doubt("list", words, "no list starts with that name")
    elif tag:
        r.s = r.s[:tag.start()] + " " + words + " " + r.s[tag.start() + 1:]

    # the grammar reads the rest: the lead words, the date, time and repeat words, and what is left is the title
    g = GR.read(re.sub(r"\s+", " ", r.s).strip(), language="en", asker="organizer", now=now.replace(tzinfo=None), today=today,
                mark_late=late_night)
    kind, remind_cue = g["kind"] or "task", g["remind"]
    if kind == "buy" and g["lead"]:
        part("type", "A thing to buy", g["lead"].strip(), "a line that starts 'buy' is a thing to buy")
    elif kind == "buy":
        part("type", "A thing to buy", g["tail"].strip(), "'to the shopping list' says it is a thing to buy")
    if remind_cue:
        part("type", "A reminder", g["lead"].strip(), "'remind me' asks for a reminder at a time")
    title = re.sub(r"\u0001(\d+)\u0001", lambda x: kept[int(x.group(1))], g["title"]).strip()
    if not title:
        doubt("title", "", "nothing is left to name it")

    if g["found"] and _past_event(line):
        # told as something that happened, not asked for: no reminder is made from it (not built: what_happened)
        said_words = " ".join(w for _a, _b, w in g["spans"])
        out["unsure"] = [{"what": "date", "said": said_words, "why": "this reads as something that already happened, so no reminder is made"}]
        out["plain_reason"] = _reason(out["unsure"])
        out["understood"] = got
        out["happened"] = _happened(line, said_words, g["readings"], today)
        return out
    readings = _ordered(g["readings"], title)
    if g.get("leftover") and readings:
        readings = [(sc, mk + [("leftover", p) for p in g["leftover"]]) for sc, mk in readings]
    if choose and readings:
        # tapped choices ({part: key}): only the readings that have them remain; once nothing is left to choose the line is settled
        chosen = [rd for rd in readings if all(i < len(rd[0]) and _optkey(rd[0][i]) == key for i, key in choose.items())]
        if chosen:
            readings = [rd for rd in chosen if not any(m[0] == "past" for m in rd[1])] or chosen     # a reading that has passed cannot be meant
            left, qs_left = _asks(readings, [rd for rd in readings if not any(m[0] == "past" for m in rd[1])], g["spans"], today.year)
            open_q = [x for x in qs_left if not (x.get("kind") == "span" and x["sched"] in choose)]
            if not open_q and len(readings) == 1:
                readings = [(readings[0][0], [])]
    if not g["found"]:
        if g.get("no_such_date"):
            said = re.search(r"\b(?:%s)\w*\.?\s+\d+|\b\d{1,2}/\d{1,2}\b" % "|".join(GR.MN), line, re.I)
            doubt("date", said.group(0) if said else "", "there is no such day")
        if remind_cue and not unsure:
            doubt("when", "", "a reminder was asked for but no day or time was found")
        if g.get("leftover") and not unsure:
            # nothing was read but words about a time are there: asked, not taken as a plain task with no date
            for ph in g["leftover"]:
                doubt("date", ph, "words about a time were left in the title (%s)" % ph)
            asks = ["%s — which day?" % ph for ph in g["leftover"]]
            out["readings"] = {"state": "not answered", "kept": [], "asks": asks, "ask": " · ".join(asks), "questions": [],
                               "basis": EQUAL_SHARES, "order": "nothing was read"}
        if unsure:
            out["unsure"], out["understood"] = unsure, got
            out["plain_reason"] = _reason(unsure)
            return out
        if kind == "task" and not urgent and project is None:
            out["plain_reason"] = "no date, time or repeat was found, so it is kept as a plain task"
            out["understood"] = got
            return out
        spec = _item(kind, title, None, None, None, urgent, project, today, line, remind_cue)
        out.update(spec)
        out["items"] = [spec]
        out["plain"], out["understood"] = False, got
        return out

    # a reading's schedules, as the items they make
    made = []                                          # per reading: (items, parts, says, repeats checked)
    for scheds, marks in readings:
        items, parts, says = [], [], []
        for sch in scheds:
            day, time, rep = _spec(sch, now, today)
            if rep and callable(rule_of):
                try:
                    rule_of(rep)
                except Exception as why:               # a repeat Organizer would refuse
                    doubt("repeat", sch["words"].get("day", ""), str(why))
                    rep = None
            items.append(_item(kind, title, day, time, rep, urgent, project, today, line, remind_cue, sch.get("range"), sch.get("part_of_day"), sch.get("until"),
                               sch.get("event_text") if str(sch.get("event_text") or "").startswith(("After", "Before", "When")) else None))
            p, s = _parts(sch, day, time, rep, rule_of, now, today, day_basis)
            parts += p
            says.append(s)
        made.append((items, parts, "; ".join(says), marks))

    live_only = [rd for rd in readings if not any(m[0] == "past" for m in rd[1])]
    if live_only and len(live_only) < len(readings):
        # a reading that has already passed was an alternative that cannot happen: what was in doubt about it (the day that just ended
        # before 4 AM, last year's date) is not a question for the ones that can
        drop = ("pastyear", "late") if len(live_only) == 1 else ("late",)
        strip = lambda mk: [m for m in mk if m[0] not in drop]
        keep_i = [i for i, rd in enumerate(readings) if rd in live_only]
        made = [(made[i][0], made[i][1], made[i][2], strip(made[i][3])) for i in keep_i]
        readings = [(rd[0], strip(rd[1])) for rd in live_only]
    if len(readings) == 1:
        # a single reading is not ambiguous (10/12 with only one valid order, 1/1): the marks that only said "which of several" go
        readings = [(readings[0][0], [m for m in readings[0][1] if m[0] not in ("slash",)])]
        made = [(made[0][0], made[0][1], made[0][2], readings[0][1])]
    marks = [mk for _sc, mk in readings]
    doubts = _doubts(marks, today, now)
    unsure += doubts
    if unsure:
        # kept whole as a plain task, with what was understood shown beside it and every reading kept
        # a reading that has already passed is not offered (the owner, 2026-10-15); if every one has, none is, and she is asked for another
        live_i = [i for i, (_sc, mk) in enumerate(readings) if not any(m[0] == "past" for m in mk)]
        r_live, m_live = [readings[i] for i in live_i], [made[i] for i in live_i]
        tags = _tags(r_live)
        learn = _learn(tags, learned)
        if learn:                                      # likeliest first by her own answers (a stable sort: ties keep the old order)
            order = sorted(range(len(r_live)), key=lambda i: -learn["probs"][i])
            r_live, m_live = [r_live[i] for i in order], [m_live[i] for i in order]
            learn = dict(learn, probs=[learn["probs"][i] for i in order], whys=[learn["whys"][i] for i in order])
            tags = (tags[0], [tags[1][i] for i in order])
        common = (m_live or made)[0][1]
        for _i, ps, _s, _m in (m_live or made)[1:]:
            common = [p for p in common if any((p["what"], p["shown"], p["from"]) == (q["what"], q["shown"], q["from"]) for q in ps)]
        out["unsure"], out["understood"] = unsure, got + common
        out["plain_reason"] = _reason(unsure)
        if title and (len(readings) > 1 or any(marks)):
            record = _record(m_live, r_live, title, line, today, _hinted(title, r_live), tags, learn)
            if tags and learned and {re.sub(r":\d+", "", k) for k in tags[0].split("+")} <= set(learned.get("off") or ()):
                record["ask_off"] = True               # her switch: this kind of question is not asked; the likeliest is taken
            record["asks"], record["questions"] = _asks(readings, r_live, g["spans"], today.year)
            if any(m[0] == "late" for ms in marks for m in ms):
                record["why"] = "It's %s. Which day did you mean?" % _clock(now.hour, now.minute)
            record["ask"] = " · ".join(record["asks"])
            out["readings"] = record
            # shown by its title, with what is unsure beside it; the words as typed stay on the item (`capture`) and one tap away
            # (the owner, 2026-10-15, "2"). The case she typed is kept.
            out["args"] = {"title": title, "text": line}
            if len(m_live) > 1:
                out["suggestions"] = [dict(label=k["label"], args=k["items"][0]["args"], type=k["items"][0]["type"],
                                           likelihood=k["likelihood"], **({"items": k["items"]} if len(k["items"]) > 1 else {}))
                                      for k in record["kept"]]
        return out

    items, parts, says, _m = made[0]
    out["understood"] = got + parts
    out.update(items[0])
    out["items"] = items
    out["plain"] = False
    out["says"] = says
    return out


def _parts(sch, day, time, rep, rule_of, now, today, basis):
    """What one schedule was read as, each part with the words it came from and why; and the sentence that says it."""
    words = sch["words"]
    parts = []
    dayw = words.get("day") or (words.get("pod") if not sch["repeat"] else "")
    timew = words.get("time") or ""
    part = sch.get("part_of_day") if not time else None
    tonight = bool(sch.get("pod")) and "tonight" in (words.get("pod") or "").lower()
    if not rep and day is not None:
        parts.append({"what": "date", "shown": _cap(_label(day, today, tonight)), "from": dayw or "",
                      "why": str(sch.get("why") or "").replace("{basis}", basis)})
    if time:
        src = sch.get("time_src")
        if src == "pod":
            why = "'%s' settles am or pm for the hour said" % (sch.get("pod") if not tonight else "tonight")
        elif src == "24h":
            why = "a 24-hour time, kept as written"
        else:
            why = "the time as said"
        parts.append({"what": "time", "shown": _clock(*time), "from": timew or "", "why": why})
    if part:
        parts.append({"what": "part of day", "shown": _cap(part), "from": words.get("pod", ""),
                      "why": "no hour was said, so none is kept"})
    if rep:
        first = _first(rep, rule_of, day, time, now)
        parts.append({"what": "repeat", "shown": _cap(_repeat_words(rep)) + (" (first: %s)" % first if first else ""),
                      "from": words.get("day", ""), "why": "a repeat is kept as an RFC 5545 rule (%s)" % _rrule_text(rep, rule_of)})
        says = "%s%s, from '%s'" % (_cap(_repeat_words(rep)), " from " + first if first else "", _joined(words.get("day"), timew))
    else:
        head, sep, tail = _says(day, time, today, _joined(dayw, timew), None, tonight, part if part != "tonight" else None).partition(", from '")
        says = _cap(head) + sep + tail                  # her quoted words are left as she typed them
    return parts, says


def _ordered(readings, title):
    """The readings, likeliest first. Soonest first, a reading that has already passed last, the reading from the day just
    ended (before 4 AM) after the plain local one, and a hinted one ('early' with a bare hour is AM) first of all."""
    def key(rd):
        scheds, marks = rd
        first = scheds[0] if scheds else {}
        d = first.get("date")
        return (any(s.get("alt") for s in scheds), any(m[0] == "past" for m in marks), d.toordinal() if d else 10 ** 7,
                0 if first.get("until") else 1, first.get("time") or (-1, -1), str(sorted(str(s.get("range")) for s in scheds)))
    out = sorted(readings, key=key)
    if _hinted(title, out):
        out.sort(key=lambda rd: not all(s.get("time") and s["time"][0] < 12 for s in rd[0]))
    return out


def _hinted(title, readings):
    """The hint a word of the title gives (AM for 'early'), when the readings differ in am or pm."""
    if not any(w in HINTS for w in re.findall(r"[a-z]+", title.lower())):
        return None
    halves = {tuple(s["time"][0] < 12 for s in rd[0] if s.get("time")) for rd in readings}
    return "AM" if len(halves) > 1 else None


def _doubts(marks_per_reading, today, now):
    """What the readings are in doubt about, each once, as the person is told it."""
    seen, out = set(), []
    every_mark = [m for ms in marks_per_reading for m in ms]
    pastyear = any(m[0] == "pastyear" for m in every_mark)
    for m in every_mark:
        if m in seen:
            continue
        seen.add(m)
        kind = m[0]
        if kind == "ampm":
            h, mi = m[2], m[3]
            out.append({"what": "time", "said": m[1], "why": "%s could be %s or %s" % (m[1].replace("at ", ""), _clock(h % 12, mi), _clock(h % 12 + 12, mi))})
        elif kind == "next":
            out.append({"what": "date", "said": m[1], "why": "'next %s' could be the coming %s or the one after" % (m[2], m[2])})
        elif kind == "sameday":
            out.append({"what": "date", "said": m[1], "why": "today is %s: this one or next week's" % m[2]})
        elif kind == "span":
            out.append({"what": "date", "said": m[1], "why": "%s could mean any day in that %s" % (m[1], m[2])})
        elif kind == "event":
            out.append({"what": "time", "said": m[1], "why": "a time tied to something you do has no hour of its own"})
        elif kind == "leftover":
            out.append({"what": "date", "said": m[1], "why": "words about a time were left in the title (%s)" % m[1]})
        elif kind == "approx":
            out.append({"what": "date", "said": m[1], "why": "'%s' could be %d or %d %ss" % (m[1], m[2], m[3], m[4])})
        elif kind == "everyord":
            out.append({"what": "date", "said": m[1], "why": "%s could be every other week or that day of each month" % m[1]})
        elif kind == "endofweek":
            out.append({"what": "date", "said": m[1], "why": "the end of the week could be Friday or Sunday"})
        elif kind == "midmonth":
            out.append({"what": "date", "said": m[1], "why": "the middle of the month could be the 15th or the days around it"})
        elif kind == "weekend":
            out.append({"what": "date", "said": m[1], "why": "the weekend could mean any time on it, Saturday or Sunday"})
        elif kind == "slash":
            out.append({"what": "date", "said": m[1], "why": "a date with slashes could be month/day or day/month"})
        elif kind == "several":
            out.append({"what": "date", "said": m[1], "why": "more than one day was said"})
        elif kind == "pastyear":
            out.append({"what": "date", "said": m[1], "why": "%s has already passed this year, so it could be next year's date or that day of every month" % m[1]})
        elif kind == "past" and m[2] == "time" and not pastyear:
            d = dt.date.fromisoformat(m[3])
            out.append({"what": "time", "said": m[1], "why": "that time has already passed (%s %s)" % (_clock(m[4], m[5]), _label(d, today))})
        elif kind == "past" and m[2] == "pod":
            out.append({"what": "date", "said": m[1], "why": "that part of the day has passed"})
        elif kind == "past" and m[2] == "date" and not pastyear:
            out.append({"what": "date", "said": m[1], "why": "that day has passed"})
        elif kind == "midnight":
            out.append({"what": "time", "said": m[1], "why": "Organizer keeps 12:00 AM as a day with no time, so midnight cannot be kept as a time"})
        elif kind == "late":
            out.append({"what": "date", "said": m[1], "why": "it is %s: %s" % (_clock(now.hour, now.minute), LATE_NIGHT[1])})
    return out


def _typed(parts, spans):
    """The words a schedule was read from, as she typed them: her case, the stray punctuation at the ends cut. `parts` are the
    grammar's (lower-case, punctuation-free) words for the day, the time and the part of the day; `spans` the read stretches."""
    orig = [t for _a, _b, w in spans for t in w.split()]
    norm = [GR._norm(t) for t in orig]
    lo, hi = None, None
    for part in parts:
        ws = [GR._norm(w) for w in str(part or "").split()]
        for i in range(len(norm) - len(ws) + 1):
            if ws and norm[i:i + len(ws)] == ws:
                lo = i if lo is None else min(lo, i)
                hi = i + len(ws) if hi is None else max(hi, i + len(ws))
                break
    if lo is None:
        return ""
    words = [t.strip(".,;:!?()\"'") for t in orig[lo:hi]]
    while words and (not words[0] or words[0].lower() == "and"):
        words.pop(0)
    while words and (not words[-1] or words[-1].lower() == "and"):
        words.pop()
    return " ".join(words)


def _unit_of(day, until):
    """The word for a stretch of days: a weekend, a week, a month, a season, a year."""
    n = (until - day).days
    return "weekend" if (day.weekday() == 5 and n == 1) else "week" if n <= 7 else "month" if n <= 31 else "season" if n <= 120 else "year"


def _full(opt, year):
    day, time, until = opt[:3]
    if opt[3:] and opt[3]:
        return opt[3]
    if until:
        return "any time that %s (%s – %s)" % (_unit_of(day, until), day.strftime("%a %-d %b"), until.strftime("%a %-d %b"))
    return " ".join(x for x in ((_clock(*time) if time else ""),
                                (day.strftime("%A %-d %b" + ("" if day.year == year else " %Y")) if day else "")) if x)


def _choice(opt, others, year):
    """One choice as the person reads it: only what differs between the choices (the day, or the time)."""
    day, time, until = opt[:3]
    if (opt[3:] and opt[3]) or until:
        return _full(opt, year)
    bits = []
    if len({o[1] for o in others}) > 1 and time is not None:
        bits.append(_clock(*time))
    if len({o[0] for o in others}) > 1 and day is not None:
        bits.append(day.strftime("%A %-d %b" + ("" if day.year == year else " %Y")))
    return " ".join(bits) or _full(opt, year)


def _optkey(r):
    """What names one choice of a part of the line (its day, its time, the end of the days it covers, the event), as text the page sends back."""
    return "|".join(str(x) for x in (r["date"], r["time"], r.get("until"), r.get("event_text")))


def _asks(readings, live, spans, year):
    """What is unsure, one question for each part of the line that is, in plain words with the choices that can still happen
    ("next friday: Friday 16 Oct or Friday 23 Oct?"). A reading that has already passed is not offered; where every reading has
    passed the question just asks for another time. The same question is never asked twice."""
    qs, structured = [], []
    if any(m[0] == "several" for _s, ms in readings for m in ms) and any(sc[0].get("repeat") for sc, _m in readings):
        # two days joined by "and": a reminder on each, or one that repeats on both (both can be meant)
        words = []
        for x in readings[0][0]:
            w = _typed([x["words"].get("day")], spans)
            if w and w not in words:
                words.append(w)
        said = " and ".join(words) or "more than one day"
        ask = "%s: One reminder on each, or one that repeats?" % said
        each = next(sc for sc, _m in readings if not sc[0].get("repeat"))
        rep = next(sc for sc, _m in readings if sc[0].get("repeat"))
        return [ask], [{"said": said, "sched": 0, "kind": "several", "ask": ask, "title": "One reminder on each, or one that repeats?",
                        "options": [{"key": _optkey(each[0]), "label": "One reminder on each"},
                                    {"key": _optkey(rep[0]), "label": "One that repeats"}]}]
    for i in range(len(readings[0][0])):
        every, keep, shown = [], [], None
        for scheds, _marks in readings:
            if len(scheds) <= i or scheds[i].get("repeat") and not scheds[i].get("date") and len(readings[0][0]) > 1 and len(scheds) == 1:
                continue
            o = (scheds[i]["date"], scheds[i]["time"], scheds[i].get("until"), scheds[i].get("event_text"))
            if o not in every:
                every.append(o)
            shown = shown or scheds[i]
        for scheds, _marks in live:
            if len(scheds) <= i:
                continue
            o = (scheds[i]["date"], scheds[i]["time"], scheds[i].get("until"), scheds[i].get("event_text"))
            if o not in keep:
                keep.append(o)
        w = shown["words"]
        said = _typed([w.get("day"), w.get("time"), w.get("pod")], spans)
        if not said:
            continue
        if len(keep) > 1:
            names = [_choice(o, keep, year) if len(keep) > 1 else _full(o, year) for o in keep]
            qs.append("%s: %s?" % (said, _cap(names[0] if len(names) == 1 else " or ".join(names) if len(names) == 2
                                              else ", ".join(names[:-1]) + ", or " + names[-1])))
            # each choice is its own button on the screen: tapping one settles this part (what it sends back is the key)
            by_key = {}
            for scheds, _m in live:
                if len(scheds) <= i:
                    continue
                by_key.setdefault(_optkey(scheds[i]), scheds[i])
            structured.append({"said": said, "sched": i, "ask": qs[-1],
                               "title": "Which meal?" if "eating" in said.lower() else None,
                               "options": [
                {"key": k, "label": _cap(_full((r["date"], r["time"], r.get("until"), r.get("event_text")), year)).split(" (")[0] if (r.get("until") or r.get("event_text"))
                else _cap(_choice((r["date"], r["time"], r.get("until"), r.get("event_text")), keep, year)
                          if len(keep) > 1 else _full((r["date"], r["time"], r.get("until"), r.get("event_text")), year))}
                for k, r in by_key.items()]})
        elif not keep:
            qs.append("%s: Another time?" % said)
    if not qs and any(m[0] == "several" for _s, ms in readings for m in ms):
        words = []
        for x in readings[0][0]:
            w = _typed([x["words"].get("day")], spans)
            if w and w not in words:
                words.append(w)
        qs.append("%s: One reminder on each, or one that repeats?" % (" and ".join(words) or "more than one day"))
    for scheds, marks in readings[:1]:
        if any(m[0] == "event" for m in marks) and not any(r.get("repeat") for r in scheds):
            said_ev = next((m[1] for m in marks if m[0] == "event"), "")
            if said_ev:
                ask_ev = "%s: Just once, or every day?" % said_ev
                qs.append(ask_ev)
                structured.append({"said": said_ev, "sched": -1, "kind": "repeat", "ask": ask_ev, "title": "Once or every day?",
                                   "options": [{"key": "once", "label": "Just once"}, {"key": "daily", "label": "Every day"}]})
        for m in marks:
            if m[0] == "leftover":
                qs.append("%s — which day?" % m[1])
            elif m[0] == "span":
                unit = m[2]
                spanned = [r for r in scheds if r.get("until")]
                if spanned and len({(r["date"], r["until"]) for sc, _mk in readings for r in sc if r.get("until")}) == 1:
                    sp = spanned[0]
                    idx = scheds.index(sp)
                    qs.append("%s: Any time that %s (%s – %s), or set the day." % (m[1], unit, sp["date"].strftime("%a %-d %b"),
                                                                                  sp["until"].strftime("%a %-d %b")))
                    name = (sp["date"].strftime("%B") if unit == "month" else unit if unit != "season" else m[1].split()[-1])
                    yr = "" if sp["date"].year == year else " %d" % sp["date"].year
                    rng = "%d–%d %s%s" % (sp["date"].day, sp["until"].day, sp["until"].strftime("%b"), yr) if sp["date"].month == sp["until"].month \
                        else "%s – %s%s" % (sp["date"].strftime("%-d %b"), sp["until"].strftime("%-d %b"), yr)
                    structured.append({"said": m[1], "sched": idx, "kind": "span", "ask": qs[-1], "title": "Which day?", "options": [
                        {"key": _optkey(sp), "label": "Any time in %s (%s)" % (name, rng) if unit == "month" else "Any time that %s (%s)" % (unit, rng)},
                        {"key": "day", "label": "Set a day…", "action": "date"}]})
    seen, out = set(), []
    for q in qs:
        if q not in seen:
            seen.add(q)
            out.append(q)
    return out, structured


def _reason(unsure):
    return "; ".join("%s (%s)" % (u["why"], u["said"]) if u["said"] else u["why"] for u in unsure)


def _describe(items, today):
    """One reading in words, for the screen: 'Fri 16 Oct 9:00 AM' or 'every Mon, Thu 6:00 PM'."""
    out = []
    for it in items:
        a = it["args"]
        if str(a.get("notes") or "").startswith(("After ", "Before ", "When you")):
            out.append(a["notes"] + (" · every day" if a.get("repeat") else ""))     # a time tied to something she does
        elif a.get("repeat"):
            at = (a.get("start") or "")[11:16]
            out.append(_cap(_repeat_words(a["repeat"])) + ((" " + _clock(int(at[:2]), int(at[3:]))) if at else "")
                       + ((" " + a["part_of_day"]) if a.get("part_of_day") else ""))
        elif str(a.get("notes") or "").startswith("Any time that "):
            m = re.match(r"Any time that (\w+), from (.+) to (.+)$", a["notes"])
            out.append("Any time that %s · %s – %s" % m.groups() if m else a["notes"])
        else:
            d = a.get("due") or ""
            day = dt.date.fromisoformat(d[:10]) if d else None
            at = d[11:16]
            if day:
                # the relative word the lists use, with the actual day and date ("Tomorrow · Friday 16 October")
                rel = _label(day, today)
                full = day.strftime("%A %-d %B" + ("" if day.year == today.year else " %Y"))
                when = (rel[:1].upper() + rel[1:] + " · " if rel in ("today", "tomorrow", "tonight") else "") + full
            else:
                when = _cap(a.get("timing", ""))
            out.append(" ".join(x for x in ((_clock(int(at[:2]), int(at[3:])) if at else ""), when, a.get("part_of_day") or "") if x))
    return " and ".join(out)


def _record(made, readings, title, line, today, hinted, tags=None, learn=None):
    """What is kept on the item when the line is not settled: every reading with how likely it is, the question not answered."""
    n = min(len(made), KEEP_READINGS)
    if not n:
        return {"state": "not answered", "basis": EQUAL_SHARES, "kept": [], "order": "nothing offered: every reading has passed"}
    if learn and n > 1:
        shares, basis = learn["probs"][:n], learn["basis"]
    elif hinted and n > 1:
        shares = [HINTED_SHARE[0]] + [round((1 - HINTED_SHARE[0]) / (n - 1), 3)] * (n - 1)
        basis = HINTED_SHARE[1]
    else:
        shares = [round(1 / n, 3)] * n
        basis = EQUAL_SHARES
    kept = []
    for (items, _p, _s, _m), share in zip(made[:n], shares):
        its = [{"type": it["type"], "args": {k: v for k, v in it["args"].items() if k != "text"}} for it in items]
        kept.append({"label": _describe(items, today), "likelihood": share, "items": its})
        if tags and n > 1:
            kept[-1]["choice"] = tags[1][len(kept) - 1]
        if learn and n > 1:
            kept[-1]["why"] = learn["whys"][len(kept) - 1]
    # several items in each reading: the label names only the items that differ between the readings (a row is short)
    per = [[_describe([it], today) for it in items] for items, _p, _s, _m in made[:n]]
    if len({len(x) for x in per}) == 1 and len(per[0]) > 1:
        diff = [i for i in range(len(per[0])) if len({x[i] for x in per}) > 1]
        if diff:
            for k, x in zip(kept, per):
                k["label"] = " and ".join(x[i] for i in diff)
    out = {"state": "not answered", "basis": basis, "kept": kept,
           "order": ("likeliest first: by how often you picked each kind of reading" if learn and n > 1 else
                     "likeliest first: soonest first%s" % (", a hinted reading before the rest" if hinted else ""))}
    if tags and n > 1:
        out["kind"] = tags[0]
    return out


def _first(repeat, rule_of, day, time, now):
    """When a repeat first falls, from its start, as words (None when Organizer's reader is not given)."""
    if not callable(rule_of) or day is None:
        return None
    start = dt.datetime.combine(day, dt.time(*(time or (0, 0)))).replace(tzinfo=now.tzinfo)
    try:
        t = rrulestr(rule_of(repeat), dtstart=start).after(start, inc=True)
    except (ValueError, TypeError):
        return None
    if not t:
        return None
    return "%s %s" % (t.strftime("%a %-d %b"), _clock(t.hour, t.minute)) if time else t.strftime("%a %-d %b")


def _joined(*words):
    """The words a reading came from, each once (a part of the day can be the date's words and the time's)."""
    out = []
    for w in words:
        if w and not any(w.lower() in o.lower() for o in out):
            out = [o for o in out if o.lower() not in w.lower()] + [w]
    return " ".join(out)


def _says(day, time, today, words, repeat, tonight=False, part=None):
    parts = []
    if time:
        parts.append(_clock(*time))
    if day is not None:
        parts.append(_label(day, today, tonight))
    if part:
        parts.append(part)
    if repeat:
        parts.append(_repeat_words(repeat))
    return "%s, from '%s'" % (" ".join(parts), words) if words else " ".join(parts)


def _repeat_words(repeat):
    r = str(repeat)
    if r.startswith("FREQ="):
        parts = dict(p.split("=") for p in r.split(";"))
        unit = {"DAILY": "day", "WEEKLY": "week", "MONTHLY": "month", "YEARLY": "year"}[parts["FREQ"]]
        out = "every %s %ss" % (parts.get("INTERVAL", "1"), unit) if parts.get("INTERVAL", "1") != "1" else "every " + unit
        if "BYDAY" in parts:
            names = dict(MO="Mon", TU="Tue", WE="Wed", TH="Thu", FR="Fri", SA="Sat", SU="Sun")
            out += " on " + ", ".join(_nth_day(d, names) for d in parts["BYDAY"].split(","))
        if "BYMONTHDAY" in parts:
            out += " on the " + _and([_ordinal(int(d)) for d in parts["BYMONTHDAY"].split(",")])
        return out
    return {"daily": "every day", "weekdays": "every weekday", "weekends": "every weekend", "weekly": "every week",
            "fortnightly": "every other week", "monthly": "every month", "yearly": "every year"}.get(r, r)


def _ordinal(n):
    return "%d%s" % (n, "th" if 10 <= n % 100 <= 20 else {1: "st", 2: "nd", 3: "rd"}.get(n % 10, "th"))


def _and(words):
    return words[0] if len(words) == 1 else ", ".join(words[:-1]) + " and " + words[-1]


def _nth_day(code, names):
    m = re.match(r"(-?\d)([A-Z]{2})\Z", code)
    if not m:
        return names[code]
    n = int(m.group(1))
    return ("last " if n == -1 else "%s " % {1: "1st", 2: "2nd", 3: "3rd"}.get(n, "%dth" % n)) + names[m.group(2)]


def _rrule_text(repeat, rule_of):
    try:
        return rule_of(repeat) if callable(rule_of) else repeat
    except Exception:
        return repeat


def _item(kind, title, day, time, repeat, urgent, project, today, line, remind_cue, rng=None, part=None, until=None, event=None):
    """The Organizer item a reading makes (the arguments of its capture)."""
    args = {"title": title, "text": line}
    if urgent:
        args["urgent"] = True
    if project:
        args["project"] = project
    if repeat:
        args["repeat"] = repeat
        args["start"] = day.isoformat() + (" %02d:%02d" % time if time else "")      # no time said, no time kept
        if kind == "buy":
            args["type"] = "buy"
    elif kind == "buy":
        if day is not None:
            args["timing"] = _label(day, today) + ((" " + _clock(*time)) if time else "")
    elif day is not None:
        if time:
            at = "%s %02d:%02d" % (day.isoformat(), *time)
            args["due"], args["remind"] = at, at
        else:
            args["due"] = day.isoformat()
    if part and not time:
        args["part_of_day"] = part                      # the part of the day she said, with no hour made up for it
    if event:
        args["notes"] = event                           # "After dinner": what the time is tied to
    if until and day is not None:
        # a task has one date: the first day, and the days it covers said in the notes (Organizer keeps no range of days for a task)
        args["notes"] = "Any time that %s, from %s to %s" % (_unit_of(day, until), day.strftime("%A %-d %B"), until.strftime("%A %-d %B"))
    if rng:
        # Organizer keeps one time per item: the start is the time, the end is said in the notes
        args["notes"] = "from %s to %s" % (_clock(*rng[0]), _clock(*rng[1]))
    shown_as = "thing to buy" if kind == "buy" else "reminder" if (time and not repeat) or remind_cue else "task"
    return {"type": kind if kind == "buy" else "task", "shown_as": shown_as, "args": args}


def next_times(rule, start, count=3):
    """The first times a repeat falls on, from its start (RFC 5545 rule text), as the screen could show them."""
    r = rrulestr(rule, dtstart=start)
    return list(r[:count]) if hasattr(r, "__getitem__") else []
