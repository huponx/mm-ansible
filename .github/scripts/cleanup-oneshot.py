#!/usr/bin/env python3
"""Remove one-shot options from the inventory after a successful deploy.

Some options only have to be set for one run and must be removed afterwards:

  group A  rotate_password, recreate, force, keys_absent, revoke_roles (keys of a list item)
           postgres_rotate_passwords, postgres_allow_drop_databases (top level, set back to false)
  group B  whole list items with `state: absent` (they have been applied)

The files are edited as text, line by line, so comments and formatting stay exactly as they are
(ruamel.yaml is only used to find where each item starts). The vault files are never opened.

An option that is not safe to remove yet is kept and listed in the report with the reason:
  - rotate_password of a user whose login check failed in the deploy log
  - state: absent of a database while postgres_allow_drop_databases is not true (nothing was dropped)

Usage:
  cleanup-oneshot.py --tags "postgres_users,secrets" --log ansible.log --report cleanup-report.md
  cleanup-oneshot.py --tags "" ...                 (empty = everything that was deployed)
"""
from __future__ import annotations

import argparse
import re
import sys
from dataclasses import dataclass, field
from pathlib import Path

from ruamel.yaml import YAML

GROUP_VARS = Path("inventories/production/group_vars/all")

# tag prefix -> file (relative to GROUP_VARS). Same split as .github/scripts/deploy-tags.sh.
TAG_FILES = {
    "postgres": "postgres.yml",
    "secrets": "k8s_secrets.yml",
    "argocd": "argocd.yml",
}

TRUE_VALUES = {"true", "yes", "on"}
# Keys removed from a list item when they are "set": a true flag, or a non-empty list.
FLAG_KEYS = ("rotate_password", "recreate", "force")
LIST_KEYS = ("keys_absent", "revoke_roles")
# Top-level booleans that are put back to false.
RESET_VARS = ("postgres_rotate_passwords", "postgres_allow_drop_databases")


def is_true(value) -> bool:
    return value is True or (isinstance(value, str) and value.strip().lower() in TRUE_VALUES)


def indent_of(line: str) -> int:
    return len(line) - len(line.lstrip(" "))


@dataclass
class Edit:
    delete: set[int] = field(default_factory=set)  # line indexes to delete
    replace: dict[int, str] = field(default_factory=dict)  # line index -> new text
    removed: list[str] = field(default_factory=list)
    kept: list[str] = field(default_factory=list)


def item_span(lines: list[str], start: int) -> tuple[int, int]:
    """Lines [start, end) of a list item that starts at `start` (the line with the dash)."""
    dash = indent_of(lines[start])
    end = start + 1
    pending = end  # first line after the last line that belongs to the item
    i = start + 1
    while i < len(lines):
        line = lines[i]
        if not line.strip():
            i += 1
            continue
        if indent_of(line) > dash:
            i += 1
            pending = i
            continue
        break
    end = pending
    return start, end


def key_span(lines: list[str], idx: int) -> tuple[int, int]:
    """Lines [idx, end) of a `key: value` line plus the deeper indented lines that follow it."""
    base = indent_of(lines[idx])
    end = idx + 1
    i = idx + 1
    while i < len(lines):
        line = lines[i]
        if not line.strip():
            i += 1
            continue
        if indent_of(line) > base:
            i += 1
            end = i
            continue
        break
    return idx, end


FLOW_KEY = r"(?:,\s*)?{key}\s*:\s*[^,}}]*"


def drop_flow_key(line: str, key: str) -> str | None:
    """Remove `key: value` from a flow mapping on one line; None when it is not there."""
    pattern = re.compile(FLOW_KEY.format(key=re.escape(key)))
    m = pattern.search(line)
    if not m:
        return None
    out = line[: m.start()] + line[m.end():]
    out = re.sub(r"\{\s*,\s*", "{ ", out)  # `{ , a: 1 }` when the first key was removed
    out = re.sub(r"\s+\}", " }", out)
    return out


def login_failures(log: str) -> set[str]:
    return set(re.findall(r"Login check failed for ([A-Za-z0-9_.@-]+?)\.?(?:\s|\"|$)", log))


def process_file(path: Path, log_failed: set[str], report: Edit) -> None:
    edit = Edit()  # line indexes are per file
    text = path.read_text()
    lines = text.split("\n")
    yaml = YAML()
    data = yaml.load(text)
    if not hasattr(data, "items"):
        return

    allow_drop = is_true(data.get("postgres_allow_drop_databases"))
    name = path.name

    for key, value in data.items():
        key_line = data.lc.key(key)[0]

        # Group A, top-level switches go back to false.
        if key in RESET_VARS and is_true(value):
            lines_before = lines[key_line]
            lines[key_line] = re.sub(r"(:\s*)(true|yes|on)\b", r"\1false", lines_before, count=1, flags=re.I)
            edit.replace[key_line] = lines[key_line]
            edit.removed.append(f"`{name}`: `{key}` set back to `false`")
            continue

        if not isinstance(value, list) or not all(hasattr(i, "items") for i in value):
            continue

        remaining = len(value)
        for idx, item in enumerate(value):
            start = value.lc.item(idx)[0]
            label = f"{key}[{item.get('name', idx)}]"
            handle_item(lines, name, key, label, item, start, log_failed, allow_drop, edit)
            if start in edit.delete:
                remaining -= 1

        if remaining == 0 and len(value) > 0:
            # Every item went away: keep a valid empty list instead of a null value.
            edit.replace[key_line] = f"{key}: []"

    new_lines = []
    for i, line in enumerate(lines):
        if i in edit.delete:
            continue
        new_lines.append(edit.replace.get(i, line))
    path.write_text("\n".join(new_lines))
    report.removed += edit.removed
    report.kept += edit.kept


def handle_item(lines, fname, key, label, item, start, log_failed, allow_drop, edit: Edit) -> None:
    # Group B: the whole item.
    if str(item.get("state", "")).strip() == "absent":
        if key == "postgres_databases" and not allow_drop:
            edit.kept.append(f"`{fname}`: `{label}` has `state: absent` but `postgres_allow_drop_databases` is not true, "
                             "so the database was not dropped")
            return
        first, end = item_span(lines, start)
        edit.delete.update(range(first, end))
        edit.removed.append(f"`{fname}`: item `{label}` (`state: absent`) removed")
        return

    # Group A: keys of the item.
    for k in FLAG_KEYS + LIST_KEYS:
        if k not in item:
            continue
        value = item[k]
        if k in FLAG_KEYS and not is_true(value):
            continue
        if k in LIST_KEYS and not value:
            continue
        if k == "rotate_password" and str(item.get("name", "")) in log_failed:
            edit.kept.append(f"`{fname}`: `{label}` keeps `rotate_password` because its login check failed in the deploy log")
            continue
        line_idx = item_key_line(lines, item, start, k)
        if line_idx is None:
            continue
        text = lines[line_idx]
        stripped = text.lstrip()
        if stripped.startswith("- ") and re.match(rf"-\s+{re.escape(k)}\s*:", stripped):
            edit.kept.append(f"`{fname}`: `{label}` has `{k}` on the dash line, remove it by hand")
            continue
        flow = drop_flow_key(text, k) if "{" in text else None
        if flow is not None:
            edit.replace[line_idx] = flow
        else:
            first, end = key_span(lines, line_idx)
            edit.delete.update(range(first, end))
        edit.removed.append(f"`{fname}`: `{k}` removed from `{label}`")


def item_key_line(lines, item, start, key) -> int | None:
    """Line index of `key` inside the item that starts at `start`."""
    if hasattr(item, "lc") and key in item.lc.data:
        return item.lc.data[key][0]
    # Flow mapping on a single line.
    return start if re.search(rf"[{{,]\s*{re.escape(key)}\s*:", lines[start]) else None


def files_for_tags(tags: str, root: Path) -> list[Path]:
    wanted = [t.strip() for t in tags.split(",") if t.strip()]
    files = []
    for prefix, fname in TAG_FILES.items():
        if not wanted or any(t.startswith(prefix) for t in wanted):
            p = root / GROUP_VARS / fname
            if p.is_file():
                files.append(p)
    return files


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--tags", default="", help="tags that were deployed (comma separated, empty = all)")
    ap.add_argument("--log", default="", help="Ansible log of the deploy (checked for failed login checks)")
    ap.add_argument("--report", default="cleanup-report.md")
    ap.add_argument("--root", default=".", help="repository root")
    args = ap.parse_args()

    root = Path(args.root)
    log = Path(args.log).read_text(errors="replace") if args.log and Path(args.log).is_file() else ""
    failed = login_failures(log)

    edit = Edit()
    for f in files_for_tags(args.tags, root):
        if f.name.endswith("_vault.yml"):  # never open vault files
            continue
        process_file(f, failed, edit)

    out = ["## One-shot options after the deploy", ""]
    out += [f"- removed: {m}" for m in edit.removed] or ["- nothing to remove"]
    if edit.kept:
        out += ["", "Kept (not safe to remove yet):", ""]
        out += [f"- {m}" for m in edit.kept]
    out += ["", "Comments written above a removed item are left in place: review them in the diff."]
    Path(args.report).write_text("\n".join(out) + "\n")
    print("\n".join(out))
    return 0


if __name__ == "__main__":
    sys.exit(main())
