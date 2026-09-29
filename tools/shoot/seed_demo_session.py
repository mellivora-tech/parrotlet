#!/usr/bin/env python3
"""为拍摄准备/还原 Parrotlet 的演示数据。

    python3 seed_demo_session.py seed     [--app-dir DIR] [--backup DIR] [--appearance dark|light]
    python3 seed_demo_session.py restore  [--app-dir DIR] [--backup DIR]
    python3 seed_demo_session.py verify   [--app-dir DIR] [--backup DIR]

`seed` 会先把你真实的 config.json / chat-sessions.json / words.json 备份到 --backup，
再把演示 session 写进去；拍完用 `restore` 还原，`verify` 用 sha256 逐文件比对。

为什么要这个脚本：拍摄用的是真实 app + 真实 API，必须临时替掉会话数据；
其中 summary.summarizedTurns 是**必须写对**的——写成 0 会让 app 在回复落地后
立刻触发后台总结，标题当场改名，成片里读作闪一下。等值写入当前轮数即可不触发
（判定见 ChatViewModel.shouldSummarizeMidChat：turns.count - summarizedTurns >= 5）。

注意：脚本只动这三个文件，不碰 app.jsonl（运行日志）。
"""
import argparse
import hashlib
import json
import os
import shutil
import sys
import uuid
from datetime import datetime, timezone

FILES = ["config.json", "chat-sessions.json", "words.json"]
DEFAULT_APP_DIR = os.path.expanduser("~/Library/Application Support/Parrotlet")

# 演示对话：站会场景的 6 轮热身，最后一条助教消息负责引出用户要打的那句
WARMUP = [
    ("user", "Let's practice a daily standup."),
    ("assistant",
     "Sure — picture it: it's 10 a.m., the whole team is on the call, and it's your turn.\n\n"
     "Tell me what you did yesterday and what you'll work on today."),
    ("user", "I finished the login page and write some tests."),
    ("assistant",
     "> I finished the login page and write some tests → I finished the login page and **wrote** some tests "
     "— 两件事都发生在昨天，动词要一致用过去式，write → wrote。\n\n"
     "That's a solid yesterday. Now the second half — what are you picking up today?"),
    ("user", "Today I will review the API docs and start the payment flow."),
    ("assistant",
     "Good. One small tweak: **I'll review the API docs, then start the payment flow** — "
     "用逗号加 then 比 and then 更顺，更像口语里自然的推进节奏。\n\n"
     "Now give me the whole standup in one go, three sentences: yesterday, today, blockers."),
]


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(65536), b""):
            h.update(chunk)
    return h.hexdigest()


def iso(minute):
    return datetime(2026, 9, 21, 1, minute, tzinfo=timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def turn(role, content, at):
    return {"at": at, "content": content, "deliveryStatus": "complete",
            "id": str(uuid.uuid4()).upper(), "role": role}


def demo_session():
    turns = [turn(r, c, iso(10 + i)) for i, (r, c) in enumerate(WARMUP)]
    return {
        "id": str(uuid.uuid4()).upper(),
        "mode": "conversation",
        "startedAt": iso(10),
        "summary": {
            "brief": "用户练习站会汇报，过去式与自然连接词有明显进步。",
            "expressions": ["I'll review the API docs, then start the payment flow."],
            "mistakes": [],
            # 关键：等于当前轮数，避免回复落地后触发后台总结改名
            "summarizedTurns": len(turns),
            "title": "站会表达练习",
            "topics": ["工作", "站会"],
            "userGoal": "用英语流畅地做每日站会汇报。",
        },
        "turns": turns,
        "updatedAt": turns[-1]["at"],
    }


def cmd_seed(args):
    os.makedirs(args.backup, exist_ok=True)
    for name in FILES:
        src = os.path.join(args.app_dir, name)
        dst = os.path.join(args.backup, name)
        if os.path.exists(src):
            shutil.copy2(src, dst)
            print(f"  备份 {name} → {dst}")
        else:
            print(f"  ⚠️  {name} 不存在，跳过备份")
    cfg_path = os.path.join(args.app_dir, "config.json")
    cfg = json.load(open(cfg_path)) if os.path.exists(cfg_path) else {}
    cfg["appearance"] = args.appearance
    with open(cfg_path, "w") as f:
        json.dump(cfg, f, ensure_ascii=False, indent=2)
    os.chmod(cfg_path, 0o600)
    with open(os.path.join(args.app_dir, "chat-sessions.json"), "w") as f:
        json.dump([demo_session()], f, ensure_ascii=False, indent=2)
    print(f"✓ 演示 session 已写入（appearance={args.appearance}，{len(WARMUP)} 轮）")


def cmd_restore(args):
    for name in FILES:
        src = os.path.join(args.backup, name)
        dst = os.path.join(args.app_dir, name)
        if not os.path.exists(src):
            print(f"  ⚠️  备份里没有 {name}，跳过")
            continue
        shutil.copy2(src, dst)
        print(f"  还原 {name}")
    cfg = os.path.join(args.app_dir, "config.json")
    if os.path.exists(cfg):
        os.chmod(cfg, 0o600)
    print("✓ 已还原，可用 verify 校验")


def cmd_verify(args):
    ok = True
    for name in FILES:
        a = os.path.join(args.backup, name)
        b = os.path.join(args.app_dir, name)
        if not (os.path.exists(a) and os.path.exists(b)):
            print(f"  ?   {name}: 有一侧缺失，跳过")
            continue
        ha, hb = sha256(a), sha256(b)
        same = ha == hb
        ok &= same
        print(f"  {'✓' if same else '✗'}  {name}: {ha[:16]} vs {hb[:16]}")
    print("✓ 全部一致" if ok else "✗ 有文件不一致")
    return 0 if ok else 1


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("command", choices=["seed", "restore", "verify"])
    p.add_argument("--app-dir", default=DEFAULT_APP_DIR)
    p.add_argument("--backup", default="/tmp/la-demo-backup")
    p.add_argument("--appearance", default="light", choices=["light", "dark", "auto"])
    args = p.parse_args()
    if args.command == "seed":
        cmd_seed(args)
    elif args.command == "restore":
        cmd_restore(args)
    else:
        sys.exit(cmd_verify(args))


if __name__ == "__main__":
    main()
