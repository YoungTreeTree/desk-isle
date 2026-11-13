#!/usr/bin/env python3
"""Manage the DeskIsle command hooks in the user's Codex hooks.json."""

import argparse
from datetime import datetime
import json
import os
from pathlib import Path
import shlex
import tempfile


EVENTS = {
    "SessionStart": "startup|resume|fork",
    "UserPromptSubmit": None,
    "PermissionRequest": None,
    "PostToolUse": "Bash|apply_patch|mcp__.*",
    "Stop": None,
    "Interrupt": None,
    "SessionEnd": None,
}

# The runner can exit as soon as the turn finishes. Deliver Stop before teardown.
SYNCHRONOUS_EVENTS = {"Stop", "Interrupt", "SessionEnd"}


def configure(path: Path, command: str, uninstall: bool, previous_commands=()) -> None:
    if path.is_symlink():
        raise ValueError(f"请手动配置符号链接 {path} 指向的文件")
    original = path.read_bytes() if path.exists() else None
    config = json.loads(original) if original is not None else {}
    if not isinstance(config, dict) or not isinstance(config.get("hooks", {}), dict):
        raise ValueError("hooks.json 的 hooks 必须是对象")
    hooks = config.setdefault("hooks", {})
    changed = False
    for event, matcher in EVENTS.items():
        groups = hooks.get(event, [])
        if not isinstance(groups, list):
            raise ValueError(f"{event} 的配置必须是列表")
        # Migration/removal is restricted to exact commands previously owned by this app.
        obsolete = set(previous_commands) - {command}
        if obsolete and not uninstall:
            updated_groups = []
            for group in groups:
                handlers = group.get("hooks", [])
                remaining = [hook for hook in handlers if hook.get("command") not in obsolete]
                if len(remaining) == len(handlers):
                    updated_groups.append(group)
                else:
                    changed = True
                    if remaining:
                        updated_groups.append(dict(group, hooks=remaining))
            groups = updated_groups
            hooks[event] = groups
        if uninstall:
            kept = []
            for group in groups:
                handlers = group.get("hooks", [])
                remaining = [hook for hook in handlers if hook.get("command") not in obsolete | {command}]
                if len(remaining) == len(handlers):
                    kept.append(group)
                else:
                    changed = True
                    if remaining:
                        kept.append(dict(group, hooks=remaining))
            if kept:
                hooks[event] = kept
            else:
                hooks.pop(event, None)
        else:
            installed = [
                hook for group in groups for hook in group.get("hooks", [])
                if hook.get("command") == command
            ]
            if installed:
                if event in SYNCHRONOUS_EVENTS:
                    for hook in installed:
                        if hook.get("async") is True:
                            del hook["async"]
                            changed = True
                continue
            handler = {"type": "command", "command": command, "timeout": 1}
            if event not in SYNCHRONOUS_EVENTS:
                handler["async"] = True
            group = {"hooks": [handler]}
            if matcher is not None:
                group["matcher"] = matcher
            hooks.setdefault(event, []).append(group)
            changed = True

    if not changed:
        print("桌屿 Hook 已是所需配置。")
        return

    path.parent.mkdir(parents=True, exist_ok=True)
    updated = json.dumps(config, ensure_ascii=False, indent=2) + "\n"
    with tempfile.NamedTemporaryFile(mode="w", encoding="utf-8", dir=path.parent, delete=False) as file:
        temporary = Path(file.name)
        file.write(updated)
    try:
        current = path.read_bytes() if path.exists() else None
        if current != original:
            raise ValueError("Codex Hook 配置刚刚被修改，请重试")
        if original is not None:
            suffix = datetime.now().strftime("%Y%m%d-%H%M%S-%f")
            backup = path.with_name(f"hooks.json.deskisle-{suffix}.bak")
            fd = os.open(backup, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
            with os.fdopen(fd, "wb") as file:
                file.write(original)
            print(f"原配置备份到 {backup}")
        temporary.replace(path)
    finally:
        temporary.unlink(missing_ok=True)
    print("已移除桌屿 Hook。" if uninstall else "已配置桌屿 Hook。在 Codex 的 Hook 设置里审核并信任后生效。")


def main() -> None:
    root = Path(__file__).resolve().parents[2]
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=Path, default=root / "build/macos/DeskIsle.app")
    parser.add_argument("--helper", type=Path)
    parser.add_argument("--codex-home", type=Path)
    parser.add_argument("--previous-command", action="append", default=[])
    parser.add_argument("--uninstall", action="store_true")
    options = parser.parse_args()
    helper = (options.helper or options.app / "Contents/Helpers/deskisle").expanduser().resolve()
    if not options.uninstall and not (helper.is_file() and os.access(helper, os.X_OK)):
        parser.error(f"找不到通知命令 {helper}")
    codex = (options.codex_home or Path(os.environ.get("CODEX_HOME") or Path.home() / ".codex")).expanduser()
    try:
        configure(codex / "hooks.json", shlex.join([str(helper), "hook", "codex"]), options.uninstall, options.previous_command)
    except (OSError, ValueError, AttributeError, TypeError) as error:
        parser.exit(1, f"无法配置桌屿 Hook。{error}\n")


if __name__ == "__main__":
    main()
