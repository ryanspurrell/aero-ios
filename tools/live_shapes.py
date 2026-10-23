#!/usr/bin/env python3
"""Writes the JSON that Aero's server answers, made by the server's own code over invented data, into AeroTests/Fixtures/live/.

Why: the app was written against branches of the server that are not what runs on the PC (2026-10-23: the day's `simple.unmarked` is
`behind` on main; the chat device refusals `devices_full` and `device_removed` exist only on branch chat-devices). Tests that decode
a hand-written shape cannot see that. These files are the shapes the code in a folder of server files (default ~/.local/bin, the
installed Aero) produces:

  org_calendar_{day,week,month,year}.json   what POST <address>/private/org {name:"calendar"} answers (organizer_service.operate
                                            "calendar" over organizer_timeline.calendar_view; aero_web.private_org adds on:true)
  rooms.json                                GET rooms.json   (fingus_messages_store.rooms_of, wrapped as aero_web.rooms_list does)
  room.json                                 GET rooms/<id>.json (store room, messages, seals_for, devices_of, wrapped as room_get does,
                                            names mapped back as MessagesClient._out does)
  devices_register_full.json                the refusal a ninth device gets, as aero_web.room_refused words it (status 400)

The messages store runs against a scratch HOME so it never touches the real database. Nothing here is from a real person: the records,
devices and keys are invented.

Usage: python3 tools/live_shapes.py [--bin DIR] [--out DIR]
"""
import argparse
import datetime as dt
import importlib.util
import json
import os
import sys
import tempfile


def load(name, folder):
    spec = importlib.util.spec_from_file_location(name, os.path.join(folder, name + ".py"))
    mod = importlib.util.module_from_spec(spec)
    sys.modules[name] = mod
    spec.loader.exec_module(mod)
    return mod


def calendar_files(bin_dir, out):
    sys.path.insert(0, bin_dir)
    TL = load("organizer_timeline", bin_dir)
    here = os.path.dirname(os.path.abspath(__file__))
    sys.path.insert(0, os.path.join(here, "..", "reader"))
    import organizer_phone_rules as R         # the service's own date helpers, as copied for the phone
    tz = dt.timezone(dt.timedelta(hours=-6))
    now = dt.datetime(2026, 10, 23, 9, 0, tzinfo=tz)

    def rec(**k):
        return dict({"type": "task", "status": "open", "locked": False}, **k)
    records = {
        "a1" * 16: rec(title="Take pills", due="2026-10-23 08:00", remind="2026-10-23 08:00"),
        "b2" * 16: rec(title="Call the dentist", due="2026-10-23 14:30"),
        "c3" * 16: rec(title="Water the plants", due="2026-10-23"),
        "d4" * 16: rec(title="Send the form", due="2026-10-23 07:00", status="done", done_at="2026-10-23 07:40"),
        "e5" * 16: rec(title="Stretch", repeat="daily", start="2026-10-20 18:00"),
        "f6" * 16: rec(title="Buy oat milk", type="buy", due="2026-10-24"),
    }

    class Book:
        now = {o: {"id": o[:8], "rec": r} for o, r in records.items()}
        versions = {}
    for span in ("day", "week", "month", "year"):
        got = TL.calendar_view(Book, span, now.date(), now, False, R.local, R.when, [], {}, TL.DEFAULT_MODE, "", None)
        with open(os.path.join(out, "org_calendar_%s.json" % span), "w") as f:
            json.dump(dict(got, on=True), f, indent=1, sort_keys=True)
            f.write("\n")


def messages_files(bin_dir, dest, aero_dir=None, name_for_refusal="devices_register_full.json"):
    home = tempfile.mkdtemp(prefix="fakehome-")
    os.environ["HOME"] = home
    sys.path.insert(0, bin_dir)
    S = load("fingus_messages_store", bin_dir)
    C = load("fingus_messages_client", bin_dir)
    S.DB = os.path.join(home, "rooms.db")
    me_id = "sub-invented-0001"
    phone = C.Device(me_id, "phoneDeviceId0001", C.ec.generate_private_key(C.ec.SECP256R1()), C.ec.generate_private_key(C.ec.SECP256R1()))
    pc = C.Device("@pc", "pc", C.ec.generate_private_key(C.ec.SECP256R1()), C.ec.generate_private_key(C.ec.SECP256R1()))
    for who, d in ((me_id, phone), ("@pc", pc)):
        S.register_device(who, d.device, C.point(d.ecdh.public_key()), C.point(d.sign.public_key()), "iPhone (Aero app)" if who == me_id else "pc")
    room = "r0123456789abcdef"
    key = C.new_room_key()
    seals = [phone.seal(room, 0, key, me_id, phone.device, C.point(phone.ecdh.public_key())),
             phone.seal(room, 0, key, "@pc", "pc", C.point(pc.ecdh.public_key()))]
    for s in seals:
        s["by_person"], s["by_device"] = me_id, phone.device
    members = [{"kind": "person", "name": me_id}, {"kind": "model", "name": "fingus", "model": "invented-model:7b"}]
    S.create(me_id, phone.device, room, "", members, seals, lambda m: True, {me_id}, sealed_by=(me_id, phone.device))
    mine = phone.encrypt(room, 0, key, "Hello")
    S.send(room, "person", me_id, mine["device"], 0, mine["iv"], mine["ct"], mine["sig"])
    # an AI's message is signed by this PC's device with the AI's name as the sender (aero_rooms_pc.encrypt)
    theirs = C.Device("fingus", "pc", pc.ecdh, pc.sign).encrypt(room, 0, key, "Hello. How can I help?")
    S.send(room, "model", "fingus", "pc", 0, theirs["iv"], theirs["ct"], theirs["sig"])

    back = {me_id: "owner"}
    signed = ("sender", "by_person")          # MessagesClient.SIGNED / NAMED, as the installed aero_web.py has them

    def ids_back(got):
        """MessagesClient._out: ids back to names; a signed field keeps the id beside it as <field>_id."""
        if isinstance(got, list):
            return [back.get(x, x) if isinstance(x, str) else ids_back(x) for x in got]
        if not isinstance(got, dict):
            return got
        res = {}
        for k, v in got.items():
            if k in back and isinstance(v, list):
                res[back[k]] = [dict(d, person_id=k) if isinstance(d, dict) else d for d in v]
                continue
            v = ids_back(v) if isinstance(v, (list, dict)) else v
            if isinstance(v, str) and v in back:
                if k in signed:
                    res[k + "_id"] = v
                v = back[v]
            res[k] = v
        return res
    # each store call goes through MessagesClient._out on its own; the answers are assembled by aero_web after that (so `me_id` stays an id)
    rows = ids_back(S.rooms_of(me_id))
    listing = {"me": "owner", "me_id": me_id, "owner": "Aryn", "profiles": {}, "my_names": {}, "rooms": rows}
    info = ids_back(S.room(room, me_id))
    got = ids_back(S.messages(room, 0))
    answer = dict(info, me="owner", owner="Aryn", holders={}, live_signers={}, voice="", writing=[], mode="", mode_kept="", mode_plain="",
                  folder=False, closed="", run=None, run_step=None, permission=None, messages=got,
                  seals=ids_back(S.seals_for(room, me_id, phone.device)), missing=ids_back(S.missing(room, me_id, phone.device)),
                  devices=ids_back(S.devices_of([me_id, "@pc"])))
    for name, value in (("rooms", listing), ("room", answer)):
        with open(os.path.join(dest, name + ".json"), "w") as f:
            json.dump(value, f, indent=1, sort_keys=True)
            f.write("\n")
    with open(os.path.join(dest, "room_id.txt"), "w") as f:
        f.write(room + "\n")
    # the ninth device: the store's own refusal, worded by aero_web.room_refused with ROOM_REFUSAL as that file has it
    import re
    words = "too many devices; remove one first"          # fingus_messages_store.register_device
    if not (isinstance(words, str) and words in open(os.path.join(bin_dir, "fingus_messages_store.py")).read()):
        raise SystemExit("the store no longer says: " + words)
    web = open(os.path.join(aero_dir or bin_dir, "aero_web.py")).read()
    pattern = re.search(r'^ROOM_REFUSAL = re\.compile\(r"(.*)"\)$', web, re.M).group(1)
    said = words if re.match(pattern, words) else "That isn't allowed here."
    with open(os.path.join(dest, name_for_refusal), "w") as f:
        json.dump({"error": said}, f)
        f.write("\n")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--bin", default=os.path.expanduser("~/.local/bin"))
    here = os.path.dirname(os.path.abspath(__file__))
    ap.add_argument("--out", default=os.path.join(here, "..", "AeroTests", "Fixtures", "live"))
    ap.add_argument("--aero", default=None, help="the folder holding aero_web.py, when it is not --bin (a repository checkout)")
    ap.add_argument("--refusal", default="devices_register_full.json", help="the file name for the ninth device's refusal")
    ap.add_argument("--only-refusal", action="store_true", help="write only the refusal file")
    a = ap.parse_args()
    os.makedirs(a.out, exist_ok=True)
    if a.only_refusal:
        messages_files(a.bin, a.out, a.aero, a.refusal)
        return
    calendar_files(a.bin, a.out)
    messages_files(a.bin, a.out, a.aero, a.refusal)


if __name__ == "__main__":
    main()
