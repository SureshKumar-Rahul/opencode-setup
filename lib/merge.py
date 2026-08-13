#!/usr/bin/env python3
"""Deep-merge an opencode host overlay onto a base config.

Rules, per the mirroring spec:
  - objects merge recursively
  - arrays and scalars are replaced wholesale, never concatenated
  - a null value in the overlay deletes the key
"""
import json
import sys


def merge(base, overlay):
    result = dict(base)
    for key, value in overlay.items():
        if value is None:
            result.pop(key, None)
        elif isinstance(value, dict) and isinstance(result.get(key), dict):
            result[key] = merge(result[key], value)
        else:
            result[key] = value
    return result


def main(argv):
    if len(argv) != 3:
        print("usage: merge.py BASE.json OVERLAY.json", file=sys.stderr)
        return 2
    try:
        with open(argv[1]) as handle:
            base = json.load(handle)
        with open(argv[2]) as handle:
            overlay = json.load(handle)
    except (OSError, json.JSONDecodeError) as err:
        print(f"merge.py: {err}", file=sys.stderr)
        return 1
    json.dump(merge(base, overlay), sys.stdout, indent=2)
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
