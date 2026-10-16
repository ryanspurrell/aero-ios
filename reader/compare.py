"""Compare the readings written in the simulator with expected.json (the PC's answer). Exits 1 on any difference.
    python compare.py EXPECTED.json ACTUAL.json COMPARISON.json"""
import json
import sys

exp, act = (json.load(open(p)) for p in sys.argv[1:3])
diff = sorted(i for i in set(exp) | set(act) if exp.get(i) != act.get(i))
summary = {"lines": len(exp), "matched": len(exp) - len([i for i in diff if i in exp]), "different": diff}
json.dump(summary, open(sys.argv[3], "w"), indent=1)
print("matched %d of %d lines" % (summary["matched"], summary["lines"]))
if diff:
    print("different:", ", ".join(diff[:40]))
    sys.exit(1)
