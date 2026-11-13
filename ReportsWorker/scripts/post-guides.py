#!/usr/bin/env python3
"""The two pinned, locked how-to posts in the public forums, as the
"Wingcord" bot: each an embed with a button and links under it. The button —
Report a bug, or Suggest a feature — opens a form for anyone in the server
(phase 7, docs/BUG-REPORTING.md D32); it needs the Worker that answers it, so
this is run again after that deploy. Run by Alex, from Terminal:

    python3 ~/Desktop/Wingcord-macOS/ReportsWorker/scripts/post-guides.py

It asks for the bot's token at a hidden prompt (Developer Portal → Bot), uses
it for these few requests, and keeps it nowhere. A post the bot already made
is rewritten in place — still pinned, still locked; a missing one is created.
`--dry-run` prints what would be sent, and needs no token.
"""

import getpass
import json
import sys
import urllib.error
import urllib.request

API = "https://discord.com/api/v10"
GUILD = "1569246334869831760"
BUGS_FORUM = "1570702237506871306"
IDEAS_FORUM = "1569694924104925216"
PINNED = 1 << 1
# The app icon's orange.
COLOR = 0xFF7B1C
TRACKER = "https://github.com/WingcordApp/wingcord"

BUG_GUIDE = """Found something that doesn't work? Report it from Wingcord: **Help ▸ Report a Bug…**, or type `/bug` in any message box — it's never sent to Discord. Can't open Wingcord? Press **Report a bug** below.

**How it works**
1. Say what happened, and how to make it happen again if you know.
2. Wingcord adds what it was doing — no names, messages, addresses or tokens — and **See What's Sent…** shows every file before it leaves your Mac. A picture of the window is yours to add.
3. Press **Send Report**. You get a number like `WC-4F2K` to quote, and you can follow it in **Your Reports**.
4. Confirmed bugs get their own post here and a GitHub issue, tagged **Fixed** when the fix ships. A crash several people hit is counted together, so there's no need to send it twice.

**Asked to make it happen again?** Turn on **Detailed logging for 10 minutes** in the report, repeat the problem, then send.

-# Offline? Use **Save Report…** and send the file when you're asked for it. Security problems: send them from the app only — they reach the developer privately."""

IDEA_GUIDE = """Have an idea for Wingcord? Send it from the app: **Help ▸ Suggest a Feature…**, or type `/idea` in any message box — it's never sent to Discord. Or press **Suggest a feature** below.

**How it works**
1. Say what you'd like Wingcord to do, and how you'd use it — the situation you're in matters more than the exact solution.
2. Press **Send Idea**. You get a number like `WC-7HQ2` to quote, and you can follow it in **Your Reports**.
3. Ideas worth building get their own post here and a GitHub issue, tagged **Planned**, then **Added** when they ship.

**Already here?** Vote with 👍 on its post and say how you'd use it in the thread, instead of posting it again.

-# Votes help decide what comes next."""


def link(label, url):
    return {"type": 2, "style": 5, "label": label, "url": url}


def form(label, custom_id, emoji):
    """A button the Worker answers with a form (reports.wingcord.app/discord)."""
    return {"type": 2, "style": 1, "label": label, "custom_id": custom_id, "emoji": {"name": emoji}}


GUIDES = [
    {
        "forum": BUGS_FORUM,
        "title": "📌 How to report a bug",
        "embed": {"title": "🐛 Report a bug", "description": BUG_GUIDE, "color": COLOR},
        "links": [
            form("Report a bug", "guide:bug", "🐞"),
            link("Browse the tracker", f"{TRACKER}/issues?q=is%3Aissue%20label%3Abug"),
            link("Report on GitHub", f"{TRACKER}/issues/new?template=bug_report.yml"),
        ],
    },
    {
        "forum": IDEAS_FORUM,
        "title": "📌 How to suggest a feature",
        "embed": {"title": "💡 Suggest a feature", "description": IDEA_GUIDE, "color": COLOR},
        "links": [
            form("Suggest a feature", "guide:idea", "💡"),
            link("Browse ideas", f"{TRACKER}/issues?q=is%3Aissue%20label%3Aidea"),
            link("Suggest on GitHub", f"{TRACKER}/issues/new?template=feature_idea.yml"),
        ],
    },
]


def message(guide):
    return {
        "content": "",
        "embeds": [guide["embed"]],
        "components": [{"type": 1, "components": guide["links"]}],
        "allowed_mentions": {"parse": []},
    }


def call(token, method, path, body=None):
    request = urllib.request.Request(
        API + path,
        data=None if body is None else json.dumps(body).encode(),
        method=method,
        headers={
            "Authorization": f"Bot {token}",
            "Content-Type": "application/json",
            "User-Agent": "DiscordBot (https://wingcord.app, 1)",
        },
    )
    try:
        with urllib.request.urlopen(request) as response:
            text = response.read().decode()
            return json.loads(text) if text else {}
    except urllib.error.HTTPError as error:
        detail = error.read().decode(errors="replace")
        hint = {
            50001: "the bot can't see that forum: add it to the channel's permissions",
            50013: "the bot is missing a permission there (Send Messages, Manage Threads…)",
            40067: "the forum requires a tag: turn that off for a moment, or add a tag",
        }
        try:
            code = json.loads(detail).get("code")
        except ValueError:
            code = None
        sys.exit(f"Discord said {error.code}: {detail}\n{hint.get(code, '')}".rstrip())


def main():
    if "--dry-run" in sys.argv:
        for guide in GUIDES:
            print(json.dumps({"forum": guide["forum"], "name": guide["title"], "message": message(guide)},
                             ensure_ascii=False, indent=2))
        return

    token = getpass.getpass("Paste the Wingcord bot's token (it isn't shown or kept): ").strip()
    if not token:
        sys.exit("No token, nothing posted.")
    me = call(token, "GET", "/users/@me")["id"]
    active = call(token, "GET", f"/guilds/{GUILD}/threads/active").get("threads", [])

    for guide in GUIDES:
        existing = next((thread for thread in active
                         if thread.get("parent_id") == guide["forum"]
                         and thread.get("owner_id") == me
                         and thread.get("name") == guide["title"]), None)
        if existing:
            # A forum post's first message has the post's own id.
            call(token, "PATCH", f"/channels/{existing['id']}/messages/{existing['id']}", message(guide))
            print(f"Rewritten as an embed: {guide['title']}")
        else:
            post = call(token, "POST", f"/channels/{guide['forum']}/threads",
                        {"name": guide["title"], "message": message(guide)})
            # Pinned to the top of the forum, and locked: read, not replied to.
            call(token, "PATCH", f"/channels/{post['id']}", {"flags": PINNED, "locked": True})
            print(f"Posted and pinned: {guide['title']}")


if __name__ == "__main__":
    main()
