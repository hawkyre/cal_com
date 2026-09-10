#!/usr/bin/env python3
"""Print what `source/certification.json` currently certifies.

    python3 scripts/coverage.py            # counts, then the gaps
    python3 scripts/coverage.py --gaps     # only the operations still open

An operation is only `verified` when the provider answered 2xx and the body
parsed into its generated type, so this table is the release gate: every
operation must be verified, or carry a written reason for not being.
"""

import collections
import json
import pathlib
import sys

REPORT = pathlib.Path(__file__).resolve().parent.parent / "source" / "certification.json"

STATUSES = ["verified", "refused", "unreachable", "declined", "throttled", "write", "shape_mismatch", "transport", "input"]


def load():
    report = json.loads(REPORT.read_text())
    return report, report["operations"]


def main(argv):
    report, operations = load()
    counts = collections.Counter(verdict["status"] for verdict in operations.values())
    total = len(operations)

    print(f"certification generated {report.get('generated_at', '?')}")
    print(f"account {report.get('account', '?')}")
    print(f"operations {total}\n")

    for status in STATUSES:
        count = counts.get(status, 0)
        if count:
            print(f"  {status:<14} {count:>4}  {count * 100 // total:>3}%")

    gaps = {status: [] for status in STATUSES if status != "verified"}

    for operation, verdict in sorted(operations.items()):
        if verdict["status"] != "verified":
            gaps[verdict["status"]].append((operation, verdict.get("reason", "")))

    if "--require-complete" in argv:
        # The release gate is not "everything verified" — some operations need a
        # mailbox, a second person or a payment — it is "nothing unexplained".
        unexplained = [
            operation
            for operation, verdict in sorted(operations.items())
            if verdict["status"] not in ("verified", "refused", "unreachable", "declined")
        ]
        thin = [
            operation
            for operation, verdict in sorted(operations.items())
            if verdict["status"] == "declined" and len(str(verdict.get("reason", ""))) < 20
        ]

        if unexplained or thin:
            print(f"\nunexplained: {unexplained}")
            print(f"declined without a usable reason: {thin}")
            return 1

        print("\nevery operation carries a verdict with evidence behind it")
        return 0

    if "--gaps" in argv or counts.get("verified", 0) != total:
        for status, rows in gaps.items():
            if not rows:
                continue

            print(f"\n{status} ({len(rows)}):")
            for operation, reason in rows:
                print(f"  {operation}\n      {reason}")

    return 0 if counts.get("verified", 0) == total else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
