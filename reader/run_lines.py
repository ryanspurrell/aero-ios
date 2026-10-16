"""Run the quick-add reader over lines.json at a fixed NOW and write every reading, with its likelihood, as JSON.

    python run_lines.py OUT.json            (the reader modules and lines.json sit beside this file)
Also writes OUT.json.timing.json: seconds to import, to the first reading, and per line (first pass and a second, warm pass)."""
import datetime as dt
import json
import os
import sys
import time

T0 = time.perf_counter()
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import fingus_core_reader as GR  # noqa: E402
import organizer_quickadd as Q  # noqa: E402
import rule_shim  # noqa: E402

T_IMPORT = time.perf_counter() - T0
NOW = dt.datetime(2026, 10, 14, 15, 30, tzinfo=dt.timezone.utc)      # Wed 2026-10-14 15:30, fixed so every machine reads the same moment


def _plain(o):
    if isinstance(o, (set, frozenset)):
        return sorted(o, key=str)
    return str(o)


def read_line(line):
    return {"understood": Q.understand(line, NOW, None, [], rule_shim.rule_of),
            "reader": GR.read(line, asker="quickadd", now=NOW.replace(tzinfo=None))}


def main(out):
    lines = json.load(open(os.path.join(HERE, "lines.json")))
    result, per = {}, []
    first = None
    t_start = time.perf_counter()
    for row in lines:
        a = time.perf_counter()
        result[row["id"]] = read_line(row["line"])
        d = time.perf_counter() - a
        per.append(d)
        if first is None:
            first = d
    t_pass1 = time.perf_counter() - t_start
    t2 = time.perf_counter()
    for row in lines:
        read_line(row["line"])
    t_pass2 = time.perf_counter() - t2
    with open(out, "w") as f:
        json.dump(result, f, sort_keys=True, indent=1, default=_plain, ensure_ascii=False)
    n = len(lines)
    stdlib_py = sorted({os.path.abspath(m.__file__) for m in list(sys.modules.values())
                        if getattr(m, "__file__", None) and str(m.__file__).endswith(".py")
                        and os.path.dirname(os.path.dirname(os.path.abspath(sys.modules["json"].__file__))) in os.path.abspath(m.__file__)
                        and "site-packages" not in m.__file__ and "app_packages" not in m.__file__})
    with open(out + ".timing.json", "w") as f:
        json.dump({"python": sys.version.split()[0], "lines": n, "import_s": T_IMPORT, "first_reading_s": first,
                   "pass1_total_s": t_pass1, "pass1_avg_s": t_pass1 / n, "pass2_avg_s": t_pass2 / n,
                   "stdlib_py_files_used": len(stdlib_py), "stdlib_py_bytes_used": sum(os.path.getsize(x) for x in stdlib_py if os.path.exists(x))}, f, indent=1)


if __name__ == "__main__":
    try:
        main(sys.argv[1])
    except BaseException:
        import traceback
        with open(sys.argv[1] + ".error.txt", "w") as f:
            traceback.print_exc(file=f)
        raise
