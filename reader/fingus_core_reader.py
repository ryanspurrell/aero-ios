"""The reader: a short phrase in, every reading it could have out, each with its parts, the words they came from, how likely
and why (step 1).

The simplest model: a grammar says every way a stretch of the phrase can be read. Where it can be read two ways (9 as 9 AM or 9 PM,
"next friday" as this week's or the one after, 10/12 as October 12 or 12 December) the reader finds both and keeps both. It never picks
one for the person: the part that asked (Organizer's quick add, today) asks, keeps the person's words whole and shows what was
understood. The reader owns the pieces every part shares (dates, times, numbers, durations, repeats); a part registers its own
(`register`: Organizer's lead words and its times tied to an event). Nothing here calls a model or the network.

The contract: `read(phrase, language="en", asker=..., now=..., today=..., mark_late=...)`. `language` is a parameter and "en" is the
only grammar there is (anything else is refused, not guessed); `asker` names the part that asked, which is kept on the answer. The answer
has `readings` ([(schedules, marks)]: a schedule is one date, time or repeat with the words it came from, a mark says why a reading is
not certain), `likelihood` and `why` (one share each: nothing is learned here, the part that asked puts what it has learned over them),
`spans` (the words that were read, in characters of the phrase), `title` (what is left), and the part's own lead words.

Sources and why:
- Lark (github.com/lark-parser/lark, MIT, pure Python), its Earley parser with ambiguity="explicit": the parser returns every parse of
  a stretch of words, instead of choosing one. This is the same design as Duckling and SUTime's grammars (rules over a few kinds: a
  date, a time, a repeat), with the ambiguity kept. Microsoft Recognizers-Text and Duckling keep a grammar per language; so can this.
  The grammar was measured against the rules it replaced (decision log, 2026-10-15): 7 of 102 invented lines answered with confidence
  and wrong, against 21 for the rules; it is measured the same way after every change (the quick-add line tests).
- Dates are calendar arithmetic on python's datetime; a repeat is kept as an RFC 5545 rule by the part that asked.
- The grammar is the builder's, written from invented lines; it is not a standard. Its words are a short list, not a promise of more:
  a word it does not know is left in the title.

Numbers here carry their why. Each is "picked, not grounded" until a measurement grounds it.
"""
import datetime as dt
import itertools
import re
from functools import lru_cache

from lark import Lark, Token, Transformer, Tree
from lark.exceptions import LarkError, VisitError

# What parts register (`register`): their lead words and their times tied to an event. Nothing else of a part is here.
VOCAB = {}
LANGUAGES = ("en",)

GRAMMAR = r"""
start: sched
sched: (closed AND)* schedule | timeonly | multiday
multiday: dayspec (AND dayspec)+ timeclause_any -> multi_day
schedule: closed | dayspec -> s_bare
closed: dayspec podn timeclause_any? -> s_day
      | dayspec event_p             -> s_day
      | event_p dayspec             -> s_day
      | dayspec pod timeclause_any?  -> s_day
      | dayspec timeclause_any       -> s_day
      | pod timeclause?              -> s_pod
      | dayspec rangeclause          -> s_day
timeonly: timeclause dayspec?        -> s_time
        | timeclause pod dayspec?    -> s_time
        | inpod dayspec?             -> s_time
        | rangeclause dayspec?       -> s_time
        | time_mid dayspec?          -> s_time
time_mid: mid_a | mid_b
dayspec: PREP? daylist                 -> d_days
       | EVERY daylist                  -> d_everyday
       | EVERY OTHER daylist           -> d_everyotherday
       | PREP? NEXT daylist            -> d_nextday
       | THIS SPANUNIT                 -> d_span_this
       | NEXT SPANUNIT                 -> d_span_next
       | LATER THIS SPANUNIT           -> d_span_later
       | "end" "of" (THE|THIS|NEXT)? SPANUNIT -> d_end_of
       | "in" THE? SEASON              -> d_season
       | (THIS|NEXT) SEASON            -> d_season_this
       | EVENT                         -> d_event
       | PREP? daylist EXCEPT daylist  -> d_except
       | TODAY -> d_today
       | TOMORROW -> d_tomorrow
       | YESTERDAY -> d_yesterday
       | PREP? THE ordlist            -> d_ord
       | PREP? THE ordlist OF EVERY UNIT -> d_ordmonthly
       | PREP? MONTHNAME NUMBER ORD?  -> d_monthday
       | PREP? THE? NUMBER ORD? OF? MONTHNAME -> d_monthday
       | PREP? THE? ORDINAL OF? MONTHNAME -> d_monthday_w
       | PREP? THE? ORDINAL OF THE ORDINAL -> d_monthday_ww
       | PREP? MONTHNAME THE? ORDINAL -> d_monthday_w
       | "in" MONTHNAME               -> d_month
       | PREP? ISO                     -> d_iso
       | sl_mdy | sl_dmy
       | "in" NUMBER UNIT              -> d_in
       | "in" AN UNIT                  -> d_in_one
       | "in" NUMBERW UNIT             -> d_in_w
       | NUMBER UNIT "from" "now"      -> d_in
       | NUMBERW UNIT "from" "now"     -> d_in_w
       | AN UNIT "from" "now"          -> d_in_one
       | EVERY UNIT EXCEPT daylist     -> d_everyunit_except
       | EVERY UNIT                    -> d_everyunit
       | EVERY NUMBER UNIT             -> d_everyn
       | EVERY NUMBERW UNIT            -> d_everyn_w
       | EVERY THE? ordlist OF THE UNIT -> d_ordmonthly
       | WEEKLY                        -> d_weekly
       | BIWEEKLY                      -> d_biweekly
       | WEEKLY PREP? daylist          -> d_everyday
       | PREP? daylist WEEKLY          -> d_everyday
       | ONCE "a" UNIT                 -> d_once
       | ONCE WEEKLY                   -> d_weekly
       | PREP? THE? WEEKEND_W          -> d_weekend_one
       | NEXT WEEKEND_W                -> d_weekend_next
       | EVERY OTHER UNIT              -> d_everyother
       | EVERY WEEKDAYS_W -> d_weekdays
       | WEEKDAYS_W -> d_weekdays
       | PREP? WEEKENDS_W -> d_weekends
       | EVERY WEEKENDS_W -> d_weekends
       | EVERY WEEKEND_W -> d_weekends
       | DAILY -> d_daily
       | MONTHLY -> d_monthly
       | YEARLY -> d_yearly
       | TWICE "a" UNIT                -> d_twice
       | ORDW DAYNAME OF (THE|EVERY) UNIT -> d_nth
       | ORDW DAYNAME OF (NEXT|THIS) UNIT -> d_nth_once
       | ORDW DAYNAME OF MONTHNAME    -> d_nth_once_m
       | EVERY ORDW DAYNAME           -> d_every_ord
       | EVERY UNIT PREP? THE? ordlist -> d_ordmonthly_b
       | EVERY NUMBER UNIT PREP? daylist -> d_everyn_days
       | THE? DAYAFTER                -> d_dayafter
       | LATER TODAY                  -> d_today
       | AN UNIT "from" (TODAY|TOMORROW) -> d_from_day_one
       | NUMBER UNIT "from" (TODAY|TOMORROW) -> d_from_day
       | NUMBERW UNIT "from" (TODAY|TOMORROW) -> d_from_day_w
       | NUMBER UNIT "later"          -> d_in
       | NUMBERW UNIT "later"         -> d_in_w
       | "in" "half" "an" "hour"      -> d_in_half
       | "in" "a" "couple" "of" UNIT  -> d_in_couple
       | "in" "a" "few" UNIT          -> d_in_few
       | THE? SPANUNIT "after" NEXT   -> d_span_afternext
       | ORDW SPANUNIT OF MONTHNAME   -> d_span_of_month
       | "mid" MONTHNAME              -> d_mid
       | PREP? THE ORDINAL            -> d_ord_w
       | LAST daylist                 -> d_lastday
       | LAST NIGHT_W                 -> d_lastnight
       | NUMBER UNIT AGO              -> d_ago
       | NUMBERW UNIT AGO             -> d_ago_w
       | AN UNIT AGO                  -> d_ago_one
       | "a" "couple" "of" UNIT AGO   -> d_ago_couple
       | "a" "few" UNIT AGO           -> d_ago_few
       | SOMETIME? LAST SPANUNIT      -> d_span_last
       | EVERY pod                     -> d_everypod
       | EVERY NIGHT_W                 -> d_everynight
event_p: EVENT                       -> d_event
podn: NIGHT_W
sl_mdy: NUMBER "/" NUMBER
sl_dmy: NUMBER "/" NUMBER
daylist: DAYNAME (AND? DAYNAME)*
ordlist: NUMBER ORD (AND? NUMBER ORD)*
pod: LATER? THIS? POD | LATER? TONIGHT | THIS NIGHT_W   -> pod_night
timeclause: "at" timelist | timelist_s
inpod: "at"? NUMBER "in" "the" POD   -> t_inpod
timeclause_any: timeclause | timelist
        | inpod
timelist: time (AND? time)*
timelist_s: time_s (AND? time_s)*
rangeclause: "between" time AND time -> r_between
time: time_s | t_am | t_pm | mid_a | mid_b
time_s: t_ampm | t_noon
t_ampm: NUMBER (":" NUMBER)? AMPM
t_am: NUMBER (":" NUMBER)?
t_pm: NUMBER (":" NUMBER)?
t_noon: NOON
mid_a: MIDNIGHT
mid_b: MIDNIGHT
NOON: /(noon|midday)(?![a-z])/
SPANUNIT: /(week|month|year)(?![a-z])/
LATER: "later"
SEASON: /(spring|summer|fall|autumn|winter)(?![a-z])/
EVENT: /__EVENT_PATTERN__/
MIDNIGHT: "midnight"
AND: "and"
AN: /an?(?![a-z])/
THIS: /this(?![a-z])/
NEXT: "next"
THE: "the"
OF: "of"
EVERY: /(every|each)(?![a-z])/
OTHER: "other"
EXCEPT: "except"
TWICE: "twice"
PREP: /(on|by|this)(?![a-z])/
TODAY: "today"
TOMORROW: /(tomorrow|tmrw|tmr)(?![a-z])/
YESTERDAY: "yesterday"
TONIGHT: "tonight"
DAILY: /(daily|everyday)(?![a-z])/
MONTHLY: "monthly"
YEARLY: /(yearly|annually|annual)(?![a-z])/
WEEKDAYS_W: /weekdays?(?![a-z])/
WEEKENDS_W: /weekends(?![a-z])/
WEEKEND_W: /weekend(?![a-z])/
WEEKLY: /weekly(?![a-z])/
BIWEEKLY: /(biweekly|bi-weekly|fortnightly)(?![a-z])/
ONCE: "once"
NUMBERW: /(one|two|three|four|five|six|seven|eight|nine|ten|eleven|twelve)(?![a-z])/
POD: /(morning|afternoon|evening)s?(?![a-z])/
UNIT: /(minute|min|hour|hr|day|week|fortnight|month|year)s?(?![a-z])/
DAYAFTER: /day after(?: tomorrow)?(?![a-z])/
AGO: "ago"
SOMETIME: /(sometime|some time)(?![a-z])/
NIGHT_W: "night"
LAST: "last"
AMPM: /(am|pm|a\.m\.|p\.m\.)(?![a-z])/
ORD: /(st|nd|rd|th)(?![a-z])/
ORDW: /(first|second|third|last)(?![a-z])/
ORDINAL: /(first|second|third|fourth|fifth|sixth|seventh|eighth|ninth|tenth|eleventh|twelfth|thirteenth|fourteenth|fifteenth|sixteenth|seventeenth|eighteenth|nineteenth|twentieth|twenty-first|twenty-second|twenty-third|twenty-fourth|twenty-fifth|twenty-sixth|twenty-seventh|twenty-eighth|twenty-ninth|thirtieth|thirty-first)(?![a-z])/
DAYNAME: /(mon(day)?|tue(s(day)?)?|wed(nes(day)?|s)?|thu(r(s(day)?)?)?|fri(day)?|sat(ur(day)?)?|sun(day)?)s?(?![a-z])/
MONTHNAME: /(jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)[a-z]*\.?(?![a-z])/
ISO: /\d{4}-\d{2}-\d{2}/
NUMBER: /\d+/
%import common.WS
%ignore WS
"""
_PARSER = {}


def _parser():
    """The grammar with the event words the parts registered (none: a word that cannot occur), built once for that set."""
    pattern = "|".join(v["events"]["pattern"] for v in VOCAB.values() if v.get("events")) or "\u00a7never\u00a7"
    if _PARSER.get("pattern") != pattern:
        _PARSER["parser"] = Lark(GRAMMAR.replace("__EVENT_PATTERN__", pattern), parser="earley", ambiguity="explicit", lexer="dynamic",
                                 start="start", propagate_positions=True)
        _PARSER["pattern"] = pattern
        _trees.cache_clear()
    return _PARSER["parser"]


def register(name, leads=(), tails=(), events=None):
    """A part's own words. `leads`: [(kind, regex)] words at the start of the phrase that say what kind of thing it is (kind "remind" sets
    `remind`, any other sets `kind`); `tails`: [(kind, regex, regex for a lead word that goes with it)] the same at the end; `events`:
    {"pattern": a regex of times tied to something the person does, "table": {words: [(label, part of the day)]}}."""
    VOCAB[name] = dict(leads=list(leads), tails=list(tails), events=events)
    if events:
        _parser()

DN = {"mon": 0, "tue": 1, "wed": 2, "thu": 3, "fri": 4, "sat": 5, "sun": 6}
WEEKDAYS = ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"]
MN = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"]
# hours that fit a part of the day (so "6" in "tomorrow morning at 6" is 6 AM and the 6 PM reading is dropped)
POD_H = {"morning": range(4, 12), "afternoon": range(12, 18), "evening": range(17, 24),
         "night": list(range(18, 24)) + [0, 1, 2, 3], "tonight": list(range(18, 24)) + [0, 1, 2, 3]}
# A part of the day with no hour is kept as the part of the day ("morning"), with no hour: an hour for "morning" would be a time
# nobody said (2026-10-15: no time said, no time kept). The hour comes only from a time she says, or later from her own
# waking day, labelled as such.
MAX_SPAN = 14
FEW_AGO = (2, 4)    # "a few days ago": 2 to 4 of the unit back. Picked, not grounded (no count of what people mean by "a few" yet).
ORDINAL_WORDS = ["first", "second", "third", "fourth", "fifth", "sixth", "seventh", "eighth", "ninth", "tenth", "eleventh", "twelfth",
                 "thirteenth", "fourteenth", "fifteenth", "sixteenth", "seventeenth", "eighteenth", "nineteenth", "twentieth",
                 "twenty-first", "twenty-second", "twenty-third", "twenty-fourth", "twenty-fifth", "twenty-sixth", "twenty-seventh",
                 "twenty-eighth", "twenty-ninth", "thirtieth", "thirty-first"]
NUMBER_WORDS = ["one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten", "eleven", "twelve"]
# Words in the title that have a time meaning: when one is left over after a date was read, the line is not answered with confidence
# (a number beside a unit of time, a day or month named whole, today, tomorrow, tonight, yesterday). A short day name ("sun cream")
# or "may" is no such word.
LEFTOVER = re.compile(r"\b(?:(?:\d+|%s)\s+(?:minutes?|mins?|hours?|hrs?|days?|weeks?|months?|years?)|(?:this|next|last)\s+(?:week|weekend|month|year|spring|summer|fall|autumn|winter)"
                      r"|monday|tuesday|wednesday|thursday|friday|saturday|sunday|january|february|march|april|june|july|august|"
                      r"september|october|november|december|tomorrow|tonight|today|yesterday|noon|midnight|same time)\b" % "|".join(NUMBER_WORDS))
MONTH_WORDS = {"january", "february", "march", "april", "june", "july", "august", "september", "october", "november", "december"}
MONTH_USED = {"in", "by", "before", "after", "during", "until", "till", "of", "from", "this", "next", "last", "early", "mid", "late", "on", "to", "the"}


class Bad(Exception):
    """This parse of the words cannot be a real date or time (a 25th hour, February 30)."""


def expand(t, cap=400):
    """Every tree without ambiguity nodes (Lark's explicit ambiguity keeps them as _ambig)."""
    if isinstance(t, Token):
        return [t]
    if t.data == "_ambig":
        out = []
        for c in t.children:
            out += expand(c, cap)
        return out[:cap]
    kids = [expand(c, cap) for c in t.children]
    return [Tree(t.data, list(p), t.meta) for p in itertools.islice(itertools.product(*kids), cap)]


def txt(x):
    return str(x).lower()


def is_full(tok):
    """A weekday written whole ('friday', 'fridays'), not 'fri' or 'sat'."""
    return txt(tok).rstrip("s").endswith("day")


def dn(tok):
    return DN[txt(tok)[:3]]


class T(Transformer):
    """A parse into the pieces of a schedule. Each piece that is a dict also says which words it was read from."""

    def __init__(s, text):
        super().__init__()
        s.text = text

    def _call_userfunc(s, tree, new_children=None):
        out = super()._call_userfunc(tree, new_children)
        if isinstance(out, dict):
            toks = list(tree.scan_values(lambda v: isinstance(v, Token)))
            if toks:
                a, b = min(t.start_pos for t in toks), max(t.end_pos for t in toks)
                if "times" in out or "range" in out or "inn" in out:
                    # the small word before a time ("at 9", "between 2 and 4", "in 2 hours") is part of the words said
                    m = re.search(r"(?:^|\s)(at|between|in)\s*$", s.text[:a])
                    a = m.start(1) if m else a
                out = dict(out, _w=s.text[a:b].strip())
        return out

    # times
    def t_ampm(s, c):
        h = int(c[0])
        m = int(c[1]) if len(c) == 3 else 0
        ap = txt(c[-1])[0]
        if not 1 <= h <= 12 or m > 59:
            raise Bad
        return dict(h=h % 12 + (12 if ap == "p" else 0), m=m, fixed=True, src="said")

    def _bare(s, c, pm):
        h = int(c[0])
        m = int(c[1]) if len(c) > 1 else 0
        if h > 23 or m > 59:
            raise Bad
        if h >= 13 or h == 0:
            return dict(h=h, m=m, fixed=True, src="24h")
        return dict(h=h % 12 + (12 if pm else 0), m=m, fixed=False)

    def t_am(s, c):
        return s._bare(c, False)

    def t_pm(s, c):
        return s._bare(c, True)

    def t_noon(s, c):
        return dict(h=12, m=0, fixed=True, src="said")

    def mid_a(s, c):
        return dict(h=0, m=0, fixed=True, day_off=0, midnight=True)

    def mid_b(s, c):
        return dict(h=0, m=0, fixed=True, day_off=1, midnight=True)

    def time(s, c):
        return c[0]

    def time_mid(s, c):
        return dict(times=[c[0]])

    def time_s(s, c):
        return c[0]

    def timelist(s, c):
        return [x for x in c if isinstance(x, dict)]

    def timelist_s(s, c):
        return [x for x in c if isinstance(x, dict)]

    def timeclause(s, c):
        return dict(times=c[-1])

    def timeclause_any(s, c):
        return c[0] if isinstance(c[0], dict) else dict(times=c[0])

    def inpod(s, c):
        return c[0]

    def t_inpod(s, c):
        h = int(c[0])
        pod = txt(c[-1]).rstrip("s")
        ok = [x for x in (h % 12, h % 12 + 12) if x in POD_H[pod]]
        if len(ok) != 1:
            raise Bad
        return dict(times=[dict(h=ok[0], m=0, fixed=True, src="pod")])

    def r_between(s, c):
        a, b = [x for x in c if isinstance(x, dict)]
        if not a["fixed"] and not b["fixed"] and (a["h"] >= 12) != (b["h"] >= 12):
            raise Bad                                  # "2 AM to 4 PM" from "between 2 and 4": both ends share one half-day
        if (b["h"], b["m"]) <= (a["h"], a["m"]):
            raise Bad
        return dict(range=[a, b])

    def rangeclause(s, c):
        return c[0]

    def pod_night(s, c):
        return dict(pod="night", tonight=False)

    def podn(s, c):
        return dict(pod="night", tonight=False)

    def pod(s, c):
        w = txt(c[-1]).rstrip("s")
        return dict(pod="night" if w == "tonight" else w, tonight=(w == "tonight"))

    # days
    def daylist(s, c):
        names = [x for x in c if isinstance(x, Token) and x.type == "DAYNAME"]
        return (sorted({dn(x) for x in names}), any(txt(x).endswith("days") for x in names), all(not is_full(x) for x in names))

    def ordlist(s, c):
        return [int(x) for x in c if isinstance(x, Token) and x.type == "NUMBER"]

    def d_days(s, c):
        days, plural, abbr = c[-1]
        has_prep = len(c) > 1
        # a short name alone ("sat") is a weekday only with a time or a part of the day (see interpretations);
        # several short names together ("mon wed fri") are a week's schedule
        return dict(days=days, rep="weekly" if plural or (abbr and len(days) > 1) else "", weak=abbr and len(days) == 1 and not has_prep)

    def d_everyday(s, c):
        return dict(days=c[-1][0], rep="weekly")

    def d_everyotherday(s, c):
        return dict(days=c[-1][0], rep="weekly", interval=2)

    def d_nextday(s, c):
        return dict(days=c[-1][0], nextday=True, rep="")

    def d_nth_once(s, c):
        return dict(nth_once=(txt(c[0]), dn(c[1]), txt(c[-2]), txt(c[-1]).rstrip("s")))

    def d_nth_once_m(s, c):
        return dict(nth_once=(txt(c[0]), dn(c[1]), "month_of", MN.index(txt(c[-1])[:3]) + 1))

    def d_every_ord(s, c):
        return dict(every_ord=(txt(c[1]), dn(c[2])), rep="weekly")

    def d_ordmonthly_b(s, c):
        return dict(mdays=next(x for x in c if isinstance(x, list)), rep="monthly")

    def d_everyn_days(s, c):
        days = next(x for x in c if isinstance(x, tuple))
        u = txt(next(x for x in c if isinstance(x, Token) and x.type == "UNIT")).rstrip("s")
        if u != "week":
            raise Bad
        return dict(rep="weekly", interval=int(c[1]), days=days[0])

    def d_dayafter(s, c):
        return dict(offset=2)

    def d_from_day_one(s, c):
        return dict(from_day=(1, txt(c[1]).rstrip("s"), txt(c[-1])))

    def d_from_day(s, c):
        return dict(from_day=(int(c[0]), txt(c[1]).rstrip("s"), txt(c[-1])))

    def d_from_day_w(s, c):
        return dict(from_day=(NUMBER_WORDS.index(txt(c[0])) + 1, txt(c[1]).rstrip("s"), txt(c[-1])))

    def d_in_half(s, c):
        return dict(inn=(30, "min"))

    def d_in_couple(s, c):
        return dict(inn_alt=(2, 3, txt(c[-1]).rstrip("s")))

    def d_in_few(s, c):
        return dict(inn_alt=(3, 4, txt(c[-1]).rstrip("s")))

    def d_span_afternext(s, c):
        return dict(span=("afternext", txt(c[1] if len(c) > 2 else c[0])))

    def d_span_of_month(s, c):
        return dict(span_of_month=(txt(c[0]), txt(c[1]), MN.index(txt(c[-1])[:3]) + 1))

    def d_mid(s, c):
        return dict(mid_month=MN.index(txt(c[-1])[:3]) + 1)

    def d_ord_w(s, c):
        return dict(mdays=[ORDINAL_WORDS.index(txt(c[-1])) + 1], rep="")

    def d_lastday(s, c):
        return dict(last_day=c[-1][0])

    def d_lastnight(s, c):
        return dict(offset=-1, pod="night", tonight=False, last_night=True)

    def d_ago(s, c):
        return dict(ago=(int(c[0]), txt(c[1]).rstrip("s")))

    def d_ago_w(s, c):
        return dict(ago=(NUMBER_WORDS.index(txt(c[0])) + 1, txt(c[1]).rstrip("s")))

    def d_ago_one(s, c):
        return dict(ago=(1, txt(c[1]).rstrip("s")))

    def d_ago_couple(s, c):
        return dict(ago=(2, txt(c[-2]).rstrip("s")))

    def d_ago_few(s, c):
        # "a few" is a stretch, not a number: FEW_AGO days to weeks back, kept as that range (picked, not grounded)
        return dict(ago_range=(FEW_AGO[0], FEW_AGO[1], txt(c[-2]).rstrip("s")))

    def d_span_last(s, c):
        return dict(span=("last", txt(c[-1])))

    def d_span_this(s, c):
        return dict(span=("this", txt(c[-1])))

    def d_span_next(s, c):
        return dict(span=("next", txt(c[-1])))

    def d_span_later(s, c):
        return dict(span=("later", txt(c[-1])))

    def d_end_of(s, c):
        which = next((txt(x) for x in c if isinstance(x, Token) and x.type in ("THIS", "NEXT")), "this")
        return dict(end_of=(which, txt(c[-1])))

    def d_season(s, c):
        return dict(span=("season", txt(c[-1]), "this"))

    def d_season_this(s, c):
        return dict(span=("season", txt(c[-1]), txt(c[0])))

    def d_event(s, c):
        return dict(event=" ".join(txt(c[0]).split()))

    def d_except(s, c):
        tuples = [x for x in c if isinstance(x, tuple)]
        return dict(days=[d for d in tuples[0][0] if d not in tuples[1][0]], rep="weekly")

    def d_today(s, c):
        return dict(offset=0)

    def d_tomorrow(s, c):
        return dict(offset=1)

    def d_yesterday(s, c):
        return dict(offset=-1)

    def d_ord(s, c):
        return dict(mdays=next(x for x in c if isinstance(x, list)), rep="")

    def d_ordmonthly(s, c):
        return dict(mdays=next(x for x in c if isinstance(x, list)), rep="monthly")

    def d_monthday(s, c):
        m = MN.index(txt(next(x for x in c if isinstance(x, Token) and x.type == "MONTHNAME"))[:3])
        d = int(next(x for x in c if isinstance(x, Token) and x.type == "NUMBER"))
        return dict(month=m + 1, mday=d)

    def d_month(s, c):
        m = MN.index(txt(c[-1])[:3])
        return dict(month_only=m + 1)

    def d_monthday_ww(s, c):
        ords = [txt(x) for x in c if isinstance(x, Token) and x.type == "ORDINAL"]
        m, d = ORDINAL_WORDS.index(ords[1]) + 1, ORDINAL_WORDS.index(ords[0]) + 1
        if not 1 <= m <= 12:
            raise Bad
        return dict(month=m, mday=d)

    def d_monthday_w(s, c):
        m = MN.index(txt(next(x for x in c if isinstance(x, Token) and x.type == "MONTHNAME"))[:3])
        word = txt(next(x for x in c if isinstance(x, Token) and x.type == "ORDINAL"))
        return dict(month=m + 1, mday=ORDINAL_WORDS.index(word) + 1)

    def d_iso(s, c):
        try:
            return dict(iso=dt.date.fromisoformat(str(c[-1])))
        except ValueError:
            raise Bad

    def _slash(s, c, mdy):
        a, b = int(c[0]), int(c[1])
        mo, d = (a, b) if mdy else (b, a)
        if not 1 <= mo <= 12:
            raise Bad
        return dict(month=mo, mday=d, slash=True)

    def sl_mdy(s, c):
        return s._slash(c, True)

    def sl_dmy(s, c):
        return s._slash(c, False)

    def d_in(s, c):
        return dict(inn=(int(c[0]), txt(c[1]).rstrip("s")))

    def d_in_one(s, c):
        return dict(inn=(1, txt(c[1]).rstrip("s")))

    def d_in_w(s, c):
        return dict(inn=(NUMBER_WORDS.index(txt(c[0])) + 1, txt(c[1]).rstrip("s")))

    def d_everyunit_except(s, c):
        if txt(c[1]).rstrip("s") != "day":
            raise Bad
        return dict(days=[d for d in range(7) if d not in c[-1][0]], rep="weekly")

    def d_everyunit(s, c):
        u = txt(c[1]).rstrip("s")
        if u not in ("day", "week", "month", "year"):
            raise Bad
        return dict(rep={"day": "daily", "week": "weekly", "month": "monthly", "year": "yearly"}[u], every_unit=u)

    def d_everyn(s, c):
        u = txt(c[2]).rstrip("s")
        n = int(c[1])
        if u not in ("day", "week", "month", "year") or n < 1:
            raise Bad
        return dict(rep={"day": "daily", "week": "weekly", "month": "monthly", "year": "yearly"}[u], interval=n)

    def d_everyother(s, c):
        u = txt(c[2]).rstrip("s")
        if u not in ("day", "week", "month", "year"):
            raise Bad
        return dict(rep={"day": "daily", "week": "weekly", "month": "monthly", "year": "yearly"}[u], interval=2)

    def d_everyn_w(s, c):
        u = txt(c[2]).rstrip("s")
        n = ["one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten", "eleven", "twelve"].index(txt(c[1])) + 1
        if u not in ("day", "week", "month", "year"):
            raise Bad
        return dict(rep={"day": "daily", "week": "weekly", "month": "monthly", "year": "yearly"}[u], interval=n)

    def d_weekly(s, c):
        return dict(rep="weekly")

    def d_biweekly(s, c):
        return dict(rep="weekly", interval=2)

    def d_once(s, c):
        u = txt(c[-1]).rstrip("s")
        if u not in ("day", "week", "month", "year"):
            raise Bad
        return dict(rep={"day": "daily", "week": "weekly", "month": "monthly", "year": "yearly"}[u])

    def d_weekend_one(s, c):
        return dict(weekend_one=True, rep="")

    def d_weekend_next(s, c):
        return dict(weekend_next=True, rep="")

    def d_weekdays(s, c):
        return dict(rep="weekly", days=[0, 1, 2, 3, 4], weekdays=True)

    def d_weekends(s, c):
        return dict(days=[5, 6], rep="weekly", weekend=True)

    def d_daily(s, c):
        return dict(rep="daily")

    def d_monthly(s, c):
        return dict(rep="monthly")

    def d_yearly(s, c):
        return dict(rep="yearly")

    def d_twice(s, c):
        if txt(c[-1]).rstrip("s") != "day":
            raise Bad
        return dict(rep="daily", twice=True)

    def d_nth(s, c):
        if txt(c[-1]).rstrip("s") != "month":
            raise Bad
        o = txt(c[0])
        return dict(rep="monthly", nth=({"first": 1, "second": 2, "third": 3, "last": -1}[o], dn(c[1])))

    def d_everynight(s, c):
        return dict(rep="daily", pod="night", tonight=False)

    def d_everypod(s, c):
        return dict(rep="daily", **c[-1])

    def multi_day(s, c):
        parts = [x for x in c if isinstance(x, dict)]
        when = parts[-1]
        out = []
        for ds in parts[:-1]:
            if ds.get("rep") or ds.get("span") or ds.get("event"):
                raise Bad
            out.append(s.schedule_([dict(ds), dict(when)]))
        return out

    def schedule_(s, c):
        d = {"words": {}}
        for x in c:
            if not isinstance(x, dict):
                continue
            w = x.pop("_w", None)
            kind = "time" if ("times" in x or "range" in x) else "pod" if ("pod" in x and "rep" not in x) else "day"
            if w:
                d["words"][kind] = w
            d.update({k: v for k, v in x.items()})
        return d

    def s_day(s, c):
        return s.schedule_(c)

    def s_pod(s, c):
        return s.schedule_(c)

    def s_time(s, c):
        return s.schedule_(c)

    def s_bare(s, c):
        return s.schedule_(c)

    def dayspec(s, c):
        return c[0]

    def closed(s, c):
        return c[0]

    def schedule(s, c):
        return c[0]

    def timeonly(s, c):
        return c[0]

    def sched(s, c):
        return [x for x in (c[0] if len(c) == 1 and isinstance(c[0], list) else c) if isinstance(x, dict)]

    def start(s, c):
        return c[0]


@lru_cache(maxsize=4096)
def _trees(text):
    """Every parse of `text` (a stretch of lower-case words), or None when the grammar rejects it."""
    try:
        return tuple(expand(_parser().parse(text))[:300])
    except LarkError:
        return None


def _ord(n):
    return "%d%s" % (n, "th" if 10 <= n % 100 <= 20 else {1: "st", 2: "nd", 3: "rd"}.get(n % 10, "th"))


def _add(d, n, unit):
    """A date n units on: days and weeks by days, months and years by the calendar (a month from the 14th is the 14th)."""
    unit = unit.rstrip("s")
    if unit in ("day", "week", "fortnight"):
        return d + dt.timedelta(days=n * {"day": 1, "week": 7, "fortnight": 14}[unit])
    months = n * (12 if unit == "year" else 1)
    y, m = divmod(d.month - 1 + months, 12)
    y, m = d.year + y, m + 1
    last = (dt.date(y + (m == 12), m % 12 + 1, 1) - dt.timedelta(days=1)).day
    return dt.date(y, m, min(d.day, last))


def _nth_weekday(first, weekday, which):
    """The first, second, third, fourth or last such weekday of the month that begins on `first`."""
    d = first + dt.timedelta(days=(weekday - first.weekday()) % 7)
    if which == "last":
        while (d + dt.timedelta(days=7)).month == first.month:
            d += dt.timedelta(days=7)
        return d
    return d + dt.timedelta(days=7 * {"first": 0, "second": 1, "third": 2, "fourth": 3}[which])


def _hhmm(t):
    return (t["h"], t["m"])


def resolve(sch, now, today, mark_late=False, _other=False):
    """One schedule piece -> its alternatives. Each is (list of whole schedules, marks). A mark says why that reading is
    not certain: ("ampm", words, h, m), ("next", words, name), ("sameday", words, name), ("slash", words), ("several", words),
    ("past", words, what), ("pastyear", words), ("midnight", words), ("late", words)."""
    rep = sch.get("rep", "")
    pod = sch.get("pod")
    times = sch.get("times") or []
    rng = sch.get("range")
    words = sch.get("words") or {}
    dayw, timew = words.get("day", ""), words.get("time", "")
    marks = []
    if len(times) > 1 and not rep:
        raise Bad                                      # two times for one day: not one item
    base = dict(pod=pod, words=words, range=None, time=None, pod_default=False, date=None, repeat=None, midnight=False, part_of_day=None, until=None,
                relative_day=False, tonight=bool(sch.get("tonight")), time_only=False, event_text=None)
    if rng:
        base["range"] = (_hhmm(rng[0]), _hhmm(rng[1]))
        base["time"] = _hhmm(rng[0])
        if not rng[0]["fixed"] or not rng[1]["fixed"]:
            marks.append(("ampm", timew, rng[0]["h"] % 12, rng[0]["m"]))
    time_list = [_hhmm(t) for t in times]
    base["time_src"] = (times[0].get("src") if times else None) or ("said" if rng else None)
    for t in times:
        if not t["fixed"]:
            marks.append(("ampm", timew, t["h"] % 12, t["m"]))
        if t.get("midnight"):
            marks.append(("midnight", timew or "midnight"))
    if pod and not time_list and not rng:
        base["part_of_day"] = "tonight" if sch.get("tonight") else pod
    if not time_list:
        time_list = [None]
    if rep:                                            # a repeat: one schedule per time said
        rp = dict(freq={"daily": "DAILY", "weekly": "WEEKLY", "monthly": "MONTHLY", "yearly": "YEARLY"}.get(rep), interval=sch.get("interval", 1),
                  days=sch.get("days") or [], mdays=sch.get("mdays") or [], nth=sch.get("nth"),
                  weekdays=bool(sch.get("weekdays")), weekend=bool(sch.get("weekend")))
        if rp["freq"] is None:
            raise Bad
        out = []
        for t in time_list:
            r = dict(base, repeat=rp, time=t if not rng else base["time"], date=None)
            out.append(r)
        if sch.get("every_ord"):
            ordw, wd_ = sch["every_ord"]
            rp2 = dict(rp, interval=2, days=[wd_])
            rp3 = dict(rp, freq="MONTHLY", interval=1, days=[], nth=({"first": 1, "second": 2, "third": 3, "last": -1}[ordw], wd_))
            return [([dict(r, repeat=rp2) for r in out], marks + [("everyord", dayw)]),
                    ([dict(r, repeat=rp3) for r in out], marks + [("everyord", dayw)])]
        if sch.get("event"):
            # a time tied to something she does ("every day after dinner"): one reading for each way it could be meant
            evs = _events(sch["event"])
            return [([dict(r, part_of_day=part, event_text=text) for r in out],
                     marks + ([("event", dayw or words.get("pod", ""))] if len(evs) > 1 else []))
                    for text, part in evs]
        return [(out, marks)]
    # one-offs: which dates
    dates = []
    off = sch.get("offset")
    tonight = bool(sch.get("tonight"))
    t_in = None
    if sch.get("inn"):
        n, u = sch["inn"]
        if u in ("minute", "min", "hour", "hr"):
            at = now + dt.timedelta(minutes=n) if u.startswith("min") else now + dt.timedelta(hours=n)
            at = at.replace(second=0, microsecond=0)
            r = dict(base, date=at.date(), time=(at.hour, at.minute), why="%d %s from now" % (n, u))
            return [([r], marks)]
        dates = [[(_add(today, n, u), "%d %s after {basis}" % (n, u))]]
    elif sch.get("date_next_week"):
        dates = [[(today + dt.timedelta(days=7 - today.weekday()), "'next week' is read as next Monday")]]
    elif sch.get("date_next_month"):
        nm = (today.replace(day=1) + dt.timedelta(days=32)).replace(day=1)
        dates = [[(nm, "'next month' is read as the first of next month")]]
    elif off is not None:
        dates = [[(today + dt.timedelta(days=off), {0: "today ({basis})", 1: "the day after today ({basis})"}.get(off, "the day before today ({basis})"))]]
        base["relative_day"] = off in (0, 1)
    elif sch.get("iso"):
        dates = [[(sch["iso"], "an ISO 8601 date, kept as written")]]
    elif sch.get("inn_alt"):
        a_, b_, u_ = sch["inn_alt"]
        marks.append(("approx", dayw, a_, b_, u_))
        dates = [[(today + dt.timedelta(days=n_ * {"day": 1, "week": 7, "month": 30, "fortnight": 14, "year": 365}[u_]),
                   "%d %s after {basis}" % (n_, u_))] for n_ in (a_, b_)]
    elif sch.get("from_day"):
        n_, u_, base_ = sch["from_day"]
        start_ = today + dt.timedelta(days=1 if base_ == "tomorrow" else 0)
        dates = [[(_add(start_, n_, u_), "%d %s after %s" % (n_, u_, base_))]]
    elif sch.get("ago") or sch.get("last_day") or sch.get("last_night"):
        if sch.get("ago"):
            n_, u_ = sch["ago"]
            if u_ in ("minute", "min", "hour", "hr"):          # a few minutes or hours back is the day it was that time
                d_ = (now - dt.timedelta(minutes=n_) if u_.startswith("min") else now - dt.timedelta(hours=n_)).date()
            else:
                d_ = _add(today, -n_, u_)
        elif sch.get("last_night"):
            d_ = today - dt.timedelta(days=1)
        else:
            d_ = today - dt.timedelta(days=((today.weekday() - sch["last_day"][0]) % 7) or 7)
        marks.append(("past", dayw, "date", d_.isoformat(), 0, 0))
        dates = [[(d_, "a day that has passed")]]
    elif sch.get("ago_range"):
        a_, b_, u_ = sch["ago_range"]
        if u_ not in ("day", "week", "fortnight", "month", "year"):
            raise Bad
        first_, last_ = _add(today, -b_, u_), _add(today, -a_, u_)
        marks.append(("past", dayw, "date", first_.isoformat(), 0, 0))
        dates = [[(first_, "'a few %ss ago' is read as %d to %d %ss ago, as a stretch" % (u_, a_, b_, u_), last_)]]
    elif sch.get("nth_once"):
        o_, wd_, kind_, val_ = sch["nth_once"]
        if kind_ == "month_of":
            y_, m_ = today.year, val_
            first_ = dt.date(y_ + (1 if dt.date(y_, m_, 28) < today else 0), m_, 1)
        elif val_ == "month" and kind_ == "next":
            first_ = (today.replace(day=1) + dt.timedelta(days=32)).replace(day=1)
        else:
            first_ = today.replace(day=1)
        d_ = _nth_weekday(first_, wd_, o_)
        if d_ < today and kind_ != "next" and val_ != "next":
            marks.append(("past", dayw, "date", d_.isoformat(), 0, 0))
        dates = [[(d_, "the %s %s of that month" % (o_, WEEKDAYS[wd_]))]]
    elif sch.get("span_of_month"):
        o_, u_, m_ = sch["span_of_month"]
        y_ = today.year + (1 if dt.date(today.year, m_, 28) < today else 0)
        k_ = {"first": 0, "second": 1, "third": 2, "fourth": 3}.get(o_, 0)
        start_ = dt.date(y_, m_, 1 + 7 * k_)
        marks.append(("span", dayw, "week"))
        dates = [[(start_, "that week of the month", start_ + dt.timedelta(days=6))]]
    elif sch.get("mid_month"):
        m_ = sch["mid_month"]
        y_ = today.year + (1 if dt.date(today.year, m_, 28) < today else 0)
        marks.append(("midmonth", dayw))
        dates = [[(dt.date(y_, m_, 15), "the middle of the month")],
                 [(dt.date(y_, m_, 10), "the middle of the month, as a stretch", dt.date(y_, m_, 20))]]
    elif sch.get("span"):
        start, end, unit = _span(sch["span"], today)
        marks.append(("span", dayw, unit))
        if sch["span"][0] == "last":
            marks.append(("past", dayw, "date", start.isoformat(), 0, 0))
        dates = [[(start, "the %s as a whole, any day of it" % unit, end)]]
    elif sch.get("end_of"):
        which, unit = sch["end_of"]
        if unit == "week":
            fri = today + dt.timedelta(days=(4 - today.weekday()) + (7 if which == "next" else 0))
            sun = today + dt.timedelta(days=(6 - today.weekday()) + (7 if which == "next" else 0))
            marks.append(("endofweek", dayw))
            dates = [[(fri, "the end of the working week")], [(sun, "the end of the week")]]
            d = None
        elif unit == "month":
            first = (today.replace(day=1) + dt.timedelta(days=32 * (1 if which == "next" else 0))).replace(day=1)
            d = (first.replace(day=28) + dt.timedelta(days=4)).replace(day=1) - dt.timedelta(days=1)
        else:
            d = dt.date(today.year + (1 if which == "next" else 0), 12, 31)
        if d is not None:
            dates = [[(d, "the end of the %s" % unit)]]
    elif sch.get("event") and not sch.get("days") and not sch.get("mdays") and not rep:
        dates = [[(today, "{basis}")]]
    elif sch.get("month_only"):
        mo = sch["month_only"]
        year = today.year + (1 if mo < today.month else 0)
        first = today if (year, mo) == (today.year, today.month) else dt.date(year, mo, 1)
        last = (dt.date(year + (mo == 12), mo % 12 + 1, 1) - dt.timedelta(days=1))
        marks.append(("span", dayw, "month"))
        dates = [[(first, "the month as a whole, any day of it", last)]]
    elif sch.get("month"):
        try:
            d = dt.date(today.year, sch["month"], sch["mday"])
        except ValueError:
            raise Bad
        if sch.get("slash"):
            marks.append(("slash", dayw))
        if d < today:
            try:
                nxt = dt.date(today.year + 1, sch["month"], sch["mday"])
            except ValueError:
                raise Bad
            # passed this year: next year's is the likelier, the one that passed is the other
            marks.append(("pastyear", dayw))
            dates = [[(nxt, "%s has passed this year, so it is read as next year" % dayw)], [(d, "the date as written, which has passed this year")]]
            if not sch.get("slash"):
                # the other thing "oct 3" can mean: the 3rd of every month (the second annotator's reading, kept by adjudication)
                rpm = dict(freq="MONTHLY", interval=1, days=[], mdays=[sch["mday"]], nth=None, weekdays=False, weekend=False)
                monthly = dict(base, repeat=rpm, time=time_list[0] if len(time_list) == 1 else None, date=None,
                               event_text="Every month on the %s" % _ord(sch["mday"]))
                monthly_alt = (monthly, list(marks), [("pastyear", dayw)])
        else:
            dates = [[(d, "a calendar date, kept as written")]]
    elif sch.get("mdays"):
        ds = []
        for md in sch["mdays"]:
            y, m = today.year, today.month
            for _ in range(26):
                try:
                    d = dt.date(y, m, md)
                    if d >= today:
                        break
                except ValueError:
                    pass
                m += 1
                if m > 12:
                    y, m = y + 1, 1
            else:
                raise Bad
            ds.append((d, "the next %d after {basis}" % md))
        dates = [ds]
    elif sch.get("weekend_next"):
        # "next weekend" from midweek: the coming one or the one after (asked)
        sat = today + dt.timedelta(days=(5 - today.weekday()) % 7)
        marks.append(("span", dayw, "weekend"))
        dates = [[(sat + dt.timedelta(days=7), "the weekend after the coming one", sat + dt.timedelta(days=8))],
                 [(sat, "the coming weekend", sat + dt.timedelta(days=1))]]
    elif sch.get("weekend_one"):
        marks.append(("weekend", dayw))
        sat = today + dt.timedelta(days=(5 - today.weekday()) % 7)
        sun = today + dt.timedelta(days=(6 - today.weekday()) % 7)
        if today.weekday() == 6:
            sat = today                                     # on a Sunday the weekend that is left is today
        # the weekend as a whole comes first (it is what the words say), then each day of it
        dates = [[(sat, "the weekend as a whole, any time on either day", sun)],
                 [(sat, "the coming Saturday")], [(sun, "the coming Sunday")]]
    elif sch.get("days"):
        per_day = []
        for wd in sch["days"]:
            k = (wd - today.weekday()) % 7
            name = WEEKDAYS[wd]
            if sch.get("nextday"):
                marks.append(("next", dayw, name))
                per_day.append([(today + dt.timedelta(days=k or 7), "the coming %s" % name), (today + dt.timedelta(days=(k or 7) + 7), "the %s after the coming one" % name)])
            elif k == 0:
                marks.append(("sameday", dayw, name))
                per_day.append([(today, "today ({basis}): %s" % name), (today + dt.timedelta(days=7), "next week's %s" % name)])
            else:
                per_day.append([(today + dt.timedelta(days=k), "the next %s after today ({basis})" % name)])
        dates = [list(p) for p in itertools.product(*per_day)]
        if len(sch["days"]) > 1 and not sch.get("nextday"):
            # "monday and tuesday": a reminder on each, or one that repeats on both (asked: both can be meant)
            rpw = dict(freq="WEEKLY", interval=1, days=list(sch["days"]), mdays=[], nth=None, weekdays=False, weekend=False)
            names = [WEEKDAYS[d] for d in sch["days"]]
            monthly_alt = (dict(base, repeat=rpw, time=time_list[0] if len(time_list) == 1 else None, date=None,
                                event_text="Every " + (", ".join(names[:-1]) + " and " + names[-1])), list(marks), [])
    elif pod:
        over_ = {"morning": 12, "afternoon": 17, "evening": 22}.get(pod)
        said_this = (words.get("pod") or "").startswith(("this", "later")) or tonight
        if over_ and now.hour >= over_ and not time_list[0] and not said_this:
            dates = [[(today + dt.timedelta(days=1), "that part of today is over, so tomorrow's")]]
        else:
            if over_ and now.hour >= over_ and not time_list[0] and not tonight and (words.get("pod") or "").startswith("this"):
                marks.append(("past", dayw or words.get("pod", ""), "pod", today.isoformat(), 0, 0))
            dates = [[(today, "'tonight' is today's evening ({basis})" if tonight else "'%s' is today's ({basis})" % pod)]]
    else:
        dates = [[(None, "")]]                          # time only
        base["time_only"] = True
    out = []
    monthly_alt = locals().get("monthly_alt")
    if sch.get("event") and not sch.get("days") and not sch.get("mdays") and not rep:
        for text, part in _events(sch["event"]):
            out.append(([dict(base, date=today, time=None, part_of_day=part, event_text=text, why="today, the day it was said")],
                        list(marks) + [("event", dayw or words.get("pod", ""))]))
        return out
    for ds in dates:
        scheds, mk = [], list(marks)
        for d, why, *more in ds:
            t = base["time"] if rng else (time_list[0] if len(time_list) == 1 else None)
            if d is None:
                if t is not None:
                    c = now.replace(hour=t[0], minute=t[1], second=0, microsecond=0)
                    if any(x.get("midnight") for x in times):
                        c = dt.datetime.combine(today, dt.time(0, 0))      # midnight: the start of today or the end of it, below
                    elif c <= now:
                        c += dt.timedelta(days=1)
                        why = "tomorrow, as that time has already passed today"
                    else:
                        why = "today, as that time is still to come"
                    d = c.date()
                else:
                    d = today
            r = dict(base, date=d, time=t, why=why, until=more[0] if more else None)
            if r["time"] is not None and next((x for x in times if x.get("day_off")), None):
                r["date"] = d + dt.timedelta(days=next(x for x in times if x.get("day_off"))["day_off"])
            # a time or a day already gone
            if r["time"] is not None:
                if dt.datetime.combine(r["date"], dt.time(*r["time"])) < now:
                    mk.append(("past", timew or dayw or words.get("pod", ""), "time", r["date"].isoformat(), r["time"][0], r["time"][1]))
            elif r["date"] < today:
                mk.append(("past", dayw, "date", r["date"].isoformat(), 0, 0))
            scheds.append(r)
        if len(scheds) > 1:
            mk.append(("several", dayw))
        out.append((scheds, mk))
    if monthly_alt:
        out.append(([monthly_alt[0]], list(monthly_alt[1]) + monthly_alt[2]))
    if mark_late and not _other and (off is not None or pod):
        # before 4 AM "today", "tonight" and "tomorrow" could mean the day just ended or the one starting: both are kept
        other = [([dict(r, alt=True) for r in sc], mk) for sc, mk in resolve(sch, now, today - dt.timedelta(days=1), False, True)]
        out = [(sc, mk + [("late", dayw or words.get("pod", ""))]) for sc, mk in out + other]
    return out


def _events(event):
    """(words, part of the day) for each way a time tied to an event can be meant, from the table a part registered. No hour is made up
    for any of them: a part of the day, picked, not grounded."""
    for v in VOCAB.values():
        if v.get("events") and event in v["events"]["table"]:
            return v["events"]["table"][event]
    return [(event.capitalize(), None)]


SEASONS = {"spring": (3, 5), "summer": (6, 8), "fall": (9, 11), "autumn": (9, 11), "winter": (12, 2)}   # picked, not grounded: northern hemisphere


def _span_after_next(unit, today):
    if unit == "week":
        monday = today - dt.timedelta(days=today.weekday()) + dt.timedelta(days=14)
        return monday, monday + dt.timedelta(days=6)
    first = _add(today.replace(day=1), 2 if unit == "month" else 24, "month")
    return first, _add(first, 1, "month") - dt.timedelta(days=1)


def _span(kind, today):
    """(first day, last day, the word for it) of a vague stretch of time: this week, next month, later this week, the summer."""
    k, unit = kind[0], kind[1]
    if k == "last":                                         # the stretch before this one, as a whole
        if unit == "week":
            monday = today - dt.timedelta(days=today.weekday() + 7)
            return monday, monday + dt.timedelta(days=6), "week"
        if unit == "month":
            end = today.replace(day=1) - dt.timedelta(days=1)
            return end.replace(day=1), end, "month"
        return dt.date(today.year - 1, 1, 1), dt.date(today.year - 1, 12, 31), "year"
    if k == "afternext":
        a_, b_ = _span_after_next(unit, today)
        return a_, b_, unit
    if unit == "week":
        monday = today - dt.timedelta(days=today.weekday())
        if k == "next":
            return monday + dt.timedelta(days=7), monday + dt.timedelta(days=13), "week"
        end = monday + dt.timedelta(days=6)
        start = today + dt.timedelta(days=1) if k == "later" else today
        if start > end:                                     # nothing of this week is left: the next one
            return monday + dt.timedelta(days=7), monday + dt.timedelta(days=13), "week"
        return start, end, "week"
    if unit == "month":
        first = (today.replace(day=1) + dt.timedelta(days=32 if k == "next" else 0)).replace(day=1)
        last = (first.replace(day=28) + dt.timedelta(days=4)).replace(day=1) - dt.timedelta(days=1)
        return max(first, today) if k != "next" else first, last, "month"
    if unit == "year":
        y = today.year + (1 if k == "next" else 0)
        return (dt.date(y, 1, 1) if k == "next" else today), dt.date(y, 12, 31), "year"
    # a season: its months, this one if it is not over, else the next one; "next" is the one after
    m1, m2 = SEASONS[unit]
    year = today.year
    def span(y):
        start = dt.date(y, m1, 1)
        end = dt.date(y + (1 if m2 < m1 else 0), m2, 1)
        end = (end.replace(day=28) + dt.timedelta(days=4)).replace(day=1) - dt.timedelta(days=1)
        return start, end
    start, end = span(year if m2 >= m1 else year)
    if m2 < m1 and today.month <= m2:
        start, end = span(year - 1)
    if end < today:
        start, end = span(year + 1)
    if kind[2] == "next":
        start, end = span(start.year + 1)
    return max(start, today) if kind[2] != "next" else start, end, "season"


def interpretations(text, now, today, mark_late=False):
    """All readings of one stretch of words: a list of (schedules, marks), or None if the grammar rejects it."""
    trees = _trees(text)
    if trees is None:
        return None
    res = {}
    for t in trees:
        try:
            v = T(text).transform(t)
        except (VisitError, Bad):
            continue
        if not isinstance(v, list) or not v:
            continue
        try:
            for sch in v:
                if sch.get("weak") and not (sch.get("times") or sch.get("pod") or sch.get("range")):
                    raise Bad                          # "sun cream", "sat down": a short name alone is no day
                if sch.get("pod") and sch.get("times"):
                    # the part of the day disposes of the hours the grammar proposed (the grammar proposes AM and PM)
                    if sch["pod"] in POD_H and not all(x["h"] in POD_H[sch["pod"]] for x in sch["times"]):
                        raise Bad
                    # an hour that a part of the day settles is no longer a question
                    for x in sch["times"]:
                        if not x["fixed"]:
                            x["src"] = "pod"
                        x["fixed"] = True
            alts = [([], [])]
            for sch in v:
                alts = [(a[0] + r[0], a[1] + r[1]) for a in alts for r in resolve(sch, now, today, mark_late)]
            for scheds, marks in alts:
                key = _key(scheds)
                if key in res:
                    res[key] = (res[key][0], sorted(set(res[key][1]) | set(marks), key=str))
                else:
                    res[key] = (scheds, sorted(set(marks), key=str))
        except Bad:
            continue
    return list(res.values()) or None


def _key(scheds):
    def one(r):
        rp = r["repeat"]
        return (rp and (rp["freq"], rp["interval"], tuple(rp["days"]), tuple(rp["mdays"]), rp["nth"]), r["date"], r["time"], r["range"], r.get("until"), r.get("event_text"))
    return tuple(sorted((one(r) for r in scheds), key=str))


# -- the words of the line ------------------------------------------------------------------------------------------
# words a span leaves beside it: dropped from the title only where they touch a span that was read
CONNECTORS = {"sometime", "later", "at", "on", "in", "by", "for", "from", "until", "till", "and", "to", "of", "this", "next", "every", "each", "the", "a", "an", "between"}
LEFT_ONLY = {"the", "a", "an"}                         # "on the" / "for the" stay with a span only when it reaches them


def _norm(tok):
    return tok.strip("()[]{}\"'").rstrip(".,;:?!)\"'").lower() if not re.match(r"\d{1,2}[ap]\.m\.\Z", tok.lower()) else tok.lower()


def read(phrase, language="en", asker=None, now=None, today=None, mark_late=False):
    """Read one phrase (what is left after the part took out what it keeps for itself: quotes, flags, list names).

    Returns a dict: kind (a part's, or None), remind (bool), title, readings [(schedules, marks)] in no order, likelihood (a share for
    each reading) and why, spans [(a, b, words)] in characters of `phrase`, found (a date, time or repeat words were read), lead, tail,
    language, asker. `language` other than "en" is refused: there is no other grammar yet."""
    if language not in LANGUAGES:
        raise ValueError("no grammar for language %r (only %s)" % (language, ", ".join(LANGUAGES)))
    out = _read(phrase, now, today, mark_late)
    n = len(out["readings"])
    out.update(language=language, asker=asker, likelihood=[round(1 / n, 3)] * n if n else [],
               why="picked, not grounded: equal shares, nothing has been learned from her answers yet")
    return out


def _read(text, now, today=None, mark_late=False):
    today = today or now.date()
    out = dict(kind=None, remind=False, title="", readings=[], spans=[], found=False, lead=None, tail=None)
    # "twenty second" is one word, "twenty-second"
    text = re.sub(r"\b(twenty|thirty)\s+(first|second|third|fourth|fifth|sixth|seventh|eighth|ninth)\b", r"\1-\2", text, flags=re.I)
    s = text.strip()
    if not s:
        return out
    off0 = len(text) - len(text.lstrip())
    lead_end = 0
    tail_start = len(s)
    leads = [x for v in VOCAB.values() for x in v["leads"]]
    tails = [x for v in VOCAB.values() for x in v["tails"]]
    hit = next(((kind, rx.match(s)) for kind, rx in leads if rx.match(s)), None)
    if hit:
        kind, m = hit
        if kind == "remind":
            out["remind"] = True
        else:
            out["kind"] = kind
        out["lead"], lead_end = m.group(0), m.end()
    elif not out["kind"]:
        hit = next(((kind, rx.search(s), lead) for kind, rx, lead in tails if rx.search(s)), None)
        if hit:
            kind, m, lead = hit
            out["kind"], out["tail"], tail_start = kind, m.group(0), m.start()
            m2 = lead.match(s) if lead else None
            if m2:
                lead_end = m2.end()
    toks = [(m.start(), m.end(), m.group(0)) for m in re.finditer(r"\S+", text)
            if m.start() - off0 >= lead_end and m.end() - off0 <= tail_start]
    n = len(toks)
    low = [_norm(t[2]) for t in toks]
    # the longest stretches the grammar accepts, left to right, not overlapping
    cands = []
    for a in range(n):
        if not low[a]:
            continue
        for b in range(a + 1, min(n, a + MAX_SPAN) + 1):
            if not low[b - 1]:
                break
            r = interpretations(" ".join(low[a:b]), now, today, mark_late)
            if r:
                cands.append((b - a, a, b, r))
    taken, chosen = set(), []                         # chosen: ([(a, b), ...] token ranges, readings)
    for ln, a, b, r in sorted(cands, key=lambda x: (-x[0], x[1])):
        if taken & set(range(a, b)):
            continue
        taken |= set(range(a, b))
        chosen.append(([(a, b)], r))
    chosen.sort(key=lambda c: c[0][0])
    # a day or repeat with no hour in one place and an hour alone in another ("first monday of the month, budget review at
    # 7pm") are read together as one schedule, when the grammar accepts the two joined
    only = lambda c, f: all(len(sc) == 1 and f(sc[0]) for sc, _m in c[1])
    days_only = [c for c in chosen if only(c, lambda x: x["time"] is None and not x["pod"] and not x["time_only"])]
    times_only = [c for c in chosen if only(c, lambda x: x["time_only"])]
    bare_weekly = [c for c in days_only if only(c, lambda x: x["repeat"] and x["repeat"]["freq"] == "WEEKLY" and not x["repeat"]["days"])]
    if 2 <= len(chosen) <= 3 and len(times_only) <= 1 and len(days_only) + len(times_only) == len(chosen) and (
            len(days_only) == 1 or (len(bare_weekly) == 1 and len(days_only) == 2)):
        both = sorted(chosen, key=lambda c: c[0][0])
        joined = " ".join(" ".join(low[x:y]) for c in both for x, y in c[0])
        r = interpretations(joined, now, today, mark_late)
        if r:
            chosen = [([c[0][0] for c in both], r)]
    # the title: the words not read, with the small words that touched a read stretch dropped
    for ranges, _r in chosen:
        for x, y in ranges:
            taken |= set(range(x, y))
    keep = [k for k in range(n) if k not in taken]
    keepset = set(keep)
    edge = set()
    for ranges, _r in chosen:
        for a, b in ranges:
            i = a - 1
            while i >= 0 and i in keepset and low[i] in CONNECTORS:
                edge.add(i)
                i -= 1
            j = b
            while j < n and j in keepset and low[j] in CONNECTORS and low[j] not in LEFT_ONLY:
                edge.add(j)
                j += 1
    words = []
    for k in keep:
        if k in edge:
            continue
        words.append(toks[k][2])
    title = " ".join(words)
    # a "to" left at the front after "remind me" (and "remind me tonight to ..."), and joining words at the ends
    for _ in range(4):
        title = re.sub(r"^(?:to|and|,|;|:)\s+", "", title, flags=re.I)
        title = re.sub(r"\s+(?:and|,|;|:)$", "", title, flags=re.I)
    out["title"] = title.strip(" ,;:")
    out["leftover"] = []
    if True:
        # time words left in the title: said back as she typed them (also when nothing at all was read)
        toks_left = [toks[k][2] for k in keep if k not in edge]
        norm_left = [_norm(w) for w in toks_left]
        joined = " ".join(norm_left)
        for m in LEFTOVER.finditer(joined):
            first = len(joined[:m.start()].split())
            last = first + len(m.group(0).split())
            if m.group(0) in MONTH_WORDS and not (first and norm_left[first - 1] in MONTH_USED) \
                    and not (last < len(norm_left) and re.match(r"\d", norm_left[last])):
                continue                                   # "march for rights", "august rush": a name, not a month
            phrase = " ".join(w.strip(".,;:!?()\"'") for w in toks_left[first:last])
            # "in five days": the small word before a number stays with it
            if first and norm_left[first - 1] == "in":
                phrase = "in " + phrase
            out["leftover"].append(phrase)
    if chosen:
        readings = [()]
        for _ranges, r in chosen:
            readings = [x + (y,) for x in readings for y in r]
        uniq = {}
        for rd in readings:
            scheds = [x for part in rd for x in part[0]]
            marks = sorted({mk for part in rd for mk in part[1]}, key=str)
            key = _key(scheds)
            if key in uniq:
                uniq[key] = (uniq[key][0], sorted(set(uniq[key][1]) | set(marks), key=str))
            else:
                uniq[key] = (scheds, marks)
        out["readings"] = list(uniq.values())
        out["found"] = True
        out["spans"] = [(toks[a][0], toks[b - 1][1], text[toks[a][0]:toks[b - 1][1]]) for ranges, _r in chosen for a, b in ranges]
    elif re.search(r"\b(%s)\w*\.?\s+\d+" % "|".join(MN), " ".join(low)) or re.search(r"\b\d{1,2}/\d{1,2}\b", " ".join(low)):
        out["no_such_date"] = True
    return out


# -- mentions: the people and places in the words ---------------------------------------------------------------------
# The reader finds WHERE a person or a place is named and every way it could be meant; it knows nobody. Who the words are is
# the caller's to say: a part hands in the names it
# knows (`names`, `places`, already limited to what the person may see in the mode they are in) and gets spans back.
# Relation words, the places a possessive makes ("mom and dads house") and "home" / "work" / "the office" are the reader's own.
# No model, no network. Nothing is guessed: a span carries every reading and a share for each.
# word -> (relation, needs "my"/"our" before it): a plain word like "partner" or "boss" is not a relation until it is somebody's.
RELATION_WORDS = {}
RELATION_LABELS = {          # the labels a card's RELATED line may carry for each relation (iOS Contacts' own, lower case, and common custom ones)
    "mother": ("mother", "mom", "mum", "mama"), "father": ("father", "dad", "papa"), "parents": ("mother", "father", "parent"),
    "grandmother": ("grandmother", "grandma", "nana", "granny", "gran"), "grandfather": ("grandfather", "grandpa", "grandad", "granddad"),
    "sister": ("sister",), "brother": ("brother",), "aunt": ("aunt", "auntie"), "uncle": ("uncle",), "cousin": ("cousin",),
    "son": ("son", "child"), "daughter": ("daughter", "child"), "spouse": ("spouse", "wife", "husband", "partner"),
    "partner": ("partner", "girlfriend", "boyfriend", "spouse"), "manager": ("manager", "boss", "supervisor"), "assistant": ("assistant",),
}
for _rel, _words, _weak in (
        ("mother", "mom mum mother mama mommy mummy", False), ("father", "dad father papa daddy", False), ("parents", "parents", False),
        ("grandmother", "grandma grandmother granny nana nan gran", False), ("grandfather", "grandpa grandad granddad grandfather", False),
        ("sister", "sister", False), ("brother", "brother", False), ("aunt", "aunt auntie", False), ("uncle", "uncle", False),
        ("cousin", "cousin", True), ("son", "son", True), ("daughter", "daughter", True), ("spouse", "wife husband spouse", True),
        ("partner", "partner girlfriend boyfriend", True), ("manager", "boss manager", True), ("assistant", "assistant", True)):
    for _w in _words.split():
        RELATION_WORDS[_w] = (_rel, _weak)
PLACE_NOUNS = {"house": "home", "place": "home", "home": "home", "apartment": "home", "flat": "home", "condo": "home", "cabin": "home",
               "cottage": "home", "studio": "home", "office": "work", "work": "work"}
NOT_NAMES = {"i", "i'll", "i'm", "i've", "i'd", "am", "pm", "ok", "tv", "the", "a", "an", "and", "or", "my", "our", "your", "his", "her",
             "their", "mon", "tue", "wed", "thu", "fri", "sat", "sun", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday",
             "sunday", "today", "tonight", "tomorrow", "yesterday", "january", "february", "march", "april", "may", "june", "july",
             "august", "september", "october", "november", "december", "jan", "feb", "mar", "apr", "jun", "jul", "aug", "sep", "sept",
             "oct", "nov", "dec", "christmas", "easter", "halloween", "new", "next", "last", "this", "dr", "mr", "mrs", "ms", "mx"}
HOME_BEFORE = {"at", "to", "from", "near", "go", "get", "come", "head", "drive", "walk", "bring", "take", "be", "back", "leave", "then",
               "stay", "ride", "run", "fly", "my", "our"}
HOME_NOT_BEFORE = {"depot", "improvement", "page", "screen", "button", "run", "brew", "brewing", "made", "cooked", "base"}
WORK_BEFORE = {"at", "to", "from", "near", "by", "leave", "leaving", "after"}
MENTION_WHY = "picked, not grounded: equal shares, nothing has been learned from her answers yet"


def _mtok(raw):
    """A token as a lower-case word: the punctuation around it off, a curly apostrophe made straight."""
    return raw.strip("()[]{}\"'.,;:?!").lower().replace("’", "'")


def mentions(phrase, names=(), places=()):
    """The people and places named in `phrase`, as spans [{start, end, text, kind ("person"|"place"|"both"), readings, likelihood, why}] in
    characters of `phrase`, left to right. A reading is {parts, why}: parts are {type "person", word, by ("relation"|"name"), relation, form
    ("known"|"capitalised"|"word")} and {type "place", word, label ("home"|"work"|"saved"), of [indexes of the person parts that own it] | None}.
    `names`: names the part knows (full, first, nickname, other names), `places`: saved places' names. Who or where they are is not decided
    here; a span the part cannot place is for the part to drop or to ask about."""
    text = str(phrase or "")
    toks = [(m.start(), m.end(), m.group(0)) for m in re.finditer(r"\S+", text)]
    low = [_mtok(t[2]) for t in toks]
    n = len(toks)
    known = {" ".join(str(x).lower().split()) for x in names if str(x).strip()}
    saved = {" ".join(str(x).lower().split()) for x in places if str(x).strip()}
    maxw = lambda s: max([len(x.split()) for x in s] or [0])

    def base_of(w):
        """(word, possessive) of a token: "dad's" -> ("dad", "marked"); "dads" -> ("dad", "missing") when dad is a relation word."""
        for suf in ("'s", "'"):
            if w.endswith(suf) and len(w) > len(suf):
                return w[:-len(suf)], "marked"
        if w.endswith("s") and w[:-1] in RELATION_WORDS and w not in RELATION_WORDS:
            return w[:-1], "missing"
        return w, None

    def known_at(i, pool):
        """The longest stretch from token i that is a name in `pool` -> (token count, name, possessive) or None."""
        for k in range(min(maxw(pool), n - i), 0, -1):
            words = low[i:i + k]
            if " ".join(words) in pool:
                return k, " ".join(words), None
            last, poss = words[-1], None
            for suf in ("'s", "'"):
                if last.endswith(suf) and len(last) > len(suf):
                    last, poss = last[:-len(suf)], "marked"
                    break
            else:
                if last.endswith("s") and pool is known and " ".join(words[:-1] + [last[:-1]]) in pool:
                    last, poss = last[:-1], "missing"
            if poss and " ".join(words[:-1] + [last]) in pool:
                return k, " ".join(words[:-1] + [last]), poss
        return None

    def cap_name(i):
        raw = toks[i][2].strip("()[]{}\"'.,;:?!")
        base, poss = base_of(low[i])
        if i == 0 or not raw[:1].isupper() or (len(raw) > 1 and raw.isupper()) or base in NOT_NAMES or base in RELATION_WORDS \
                or base in PLACE_NOUNS or len(base) < 2 or not re.match(r"[a-z][a-z-]*\Z", base):
            return None
        return base, ("marked" if poss == "marked" else None)

    def name_part(word, form, **kw):
        return dict(type="person", word=word, by="name", relation=None, form=form, **kw)

    def owner_at(i):
        """A person named at token i -> (token count, part, possessive) or None."""
        if i >= n:
            return None
        j, my = i, False
        if low[i] in ("my", "our") and i + 1 < n:
            j, my = i + 1, True
        base, poss = base_of(low[j])
        if base in RELATION_WORDS:
            rel, weak = RELATION_WORDS[base]
            if weak and not my:
                return None
            nxt = j + 1
            # "uncle Bob": a title and a name, not the relation
            if nxt < n and not poss and low[nxt] not in NOT_NAMES:
                kn = known_at(nxt, known)
                cn = None if kn else cap_name(nxt)
                if kn or cn:
                    return nxt + (kn[0] if kn else 1) - i, name_part(kn[1] if kn else cn[0], "known" if kn else "capitalised", title=base), \
                        (kn[2] if kn else cn[1])
            return j + 1 - i, dict(type="person", word=base, by="relation", relation=rel, form="word", my=my,
                                       labels=list(RELATION_LABELS.get(rel, (rel,)))), poss
        kn = known_at(i, known)
        if kn:
            return kn[0], name_part(kn[1], "known"), kn[2]
        cn = cap_name(i)
        if cn:
            return 1, name_part(cn[0], "capitalised"), cn[1]
        return None

    out = []
    i = 0
    while i < n:
        sv = known_at(i, saved) if saved else None
        if sv:
            end = i + sv[0]
            part = dict(type="place", word=sv[1], label="saved", of=None)
            out.append(_mspan(text, toks, i, end, "place", [dict(parts=[part], why="a place you saved")]))
            i = end
            continue
        # a possessive place: "mom and dads house", "jo's office", "my sister's place"
        chain, j = [], i
        while True:
            o = owner_at(j)
            if not o:
                break
            chain.append(o)
            j += o[0]
            if j + 1 < n and low[j] in ("and", "&", ",") and owner_at(j + 1):
                j += 1
                continue
            break
        if chain and j < n and low[j] in PLACE_NOUNS and chain[-1][2]:
            people = [c[1] for c in chain]
            label = PLACE_NOUNS[low[j]]
            noun = dict(type="place", word=low[j], label=label)
            note = " (no apostrophe)" if chain[-1][2] == "missing" else ""
            names_ = " and ".join(p["word"] for p in people)
            readings = [dict(parts=people + [dict(noun, of=list(range(len(people))))], why="the %s of %s%s" % (low[j], names_, note))]
            if len(people) > 1:
                readings.append(dict(parts=people + [dict(noun, of=[len(people) - 1])],
                                     why="%s, and the %s of %s%s" % (" and ".join(p["word"] for p in people[:-1]), low[j], people[-1]["word"], note)))
            out.append(_mspan(text, toks, i, j + 1, "both", readings))
            i = j + 1
            continue
        o = owner_at(i)
        if o:
            cnt, part, _poss = o
            why = ("a relation word" if part["by"] == "relation" else "a name you know" if part["form"] == "known" else
                   "a capitalised word") + (" after a title (%s)" % part["title"] if part.get("title") else "")
            out.append(_mspan(text, toks, i, i + cnt, "person", [dict(parts=[part], why=why)]))
            i += cnt
            continue
        w = low[i]
        prev = low[i - 1] if i else ""
        nxt = low[i + 1] if i + 1 < n else ""
        if w == "home" and (prev in HOME_BEFORE or i == 0 or i == n - 1) and nxt not in HOME_NOT_BEFORE:
            out.append(_mspan(text, toks, i, i + 1, "place", [dict(parts=[dict(type="place", word="home", label="home", of=None)], why="home")]))
        elif w == "work" and prev in WORK_BEFORE:
            out.append(_mspan(text, toks, i, i + 1, "place", [dict(parts=[dict(type="place", word="work", label="work", of=None)],
                                                                   why="work, after '%s'" % prev)]))
        elif w == "office" and prev in ("the", "my", "our"):
            out.append(_mspan(text, toks, i - 1, i + 1, "place", [dict(parts=[dict(type="place", word="office", label="work", of=None)],
                                                                       why="the office")]))
        i += 1
    out.sort(key=lambda s: s["start"])
    return out


def _mspan(text, toks, a, b, kind, readings):
    k = len(readings)
    return dict(start=toks[a][0], end=toks[b - 1][1], text=text[toks[a][0]:toks[b - 1][1]].strip("()[]{}\".,;:?!"), kind=kind,
                readings=readings, likelihood=[round(1 / k, 3)] * k, why=MENTION_WHY)
