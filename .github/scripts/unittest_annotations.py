"""Turn unittest failures in a log into GitHub error annotations.

Usage: python unittest_annotations.py LOG
Job logs need a GitHub login; annotations are public, so failures can be
read from the API (check-runs/<job>/annotations) without one.
"""
import re
import sys


def esc(s: str) -> str:
    return s.replace("%", "%25").replace("\r", "%0D").replace("\n", "%0A")


text = open(sys.argv[1], encoding="utf-8", errors="replace").read()
# Blocks look like: ====\nFAIL: test_x (mod.Class.test_x)\n----\nTraceback...
blocks = re.split(r"^={50,}$", text, flags=re.M)
n = 0
for b in blocks:
    m = re.match(r"\s*(FAIL|ERROR): (\S+) \(([^)]*)\)", b)
    if not m:
        continue
    parts = b.split("-" * 70)
    body = (parts[1] if len(parts) > 1 else b).strip()
    body = "\n".join(body.splitlines()[-40:])
    print(f"::error title={m.group(1)} {m.group(3)}::{esc(body)}")
    n += 1
tail = "\n".join(text.splitlines()[-15:])
print(f"::error title=unittest summary ({n} failing)::{esc(tail)}")
