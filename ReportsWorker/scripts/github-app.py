#!/usr/bin/env python3
"""Makes the "Wingcord Reports" GitHub App from a manifest (docs/BUG-REPORTING.md
D26, §7, §12) and hands its key and webhook secret straight to the Worker.

    python3 ~/Desktop/Wingcord-macOS/ReportsWorker/scripts/github-app.py

1. Your browser opens GitHub's "Create GitHub App" page for WingcordApp, filled
   in from the manifest below. Press **Create GitHub App**.
2. GitHub sends the browser back here with a one-time code. This script trades
   it for the App's private key and webhook secret and pipes both into
   `wrangler secret bulk` — never printed, never written to disk. The App's
   client ID, which is public, goes into wrangler.jsonc.
3. The browser moves on to installing the App, with WingcordApp and its
   `wingcord` repository already chosen. Press **Install**.

Setting the secrets deploys the Worker's current code again, with them added;
the phase 7 code is deployed after this (README.md, "Phase 7").

The App asks for Issues (read and write) and Metadata (read) — nothing else —
and receives `issues` events only. It is private: only WingcordApp can
install it.
"""

import html
import json
import pathlib
import re
import secrets
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
import webbrowser
from http.server import BaseHTTPRequestHandler, HTTPServer

ORGANIZATION = "WingcordApp"
# Public ids, for the install page to open on the right account and repository.
ORGANIZATION_ID = 356132421
REPOSITORY_ID = 1456291273
WORKER = pathlib.Path(__file__).resolve().parent.parent
WRANGLER_CONFIG = WORKER / "wrangler.jsonc"
# GitHub allows an hour to trade the code; the whole thing gives up after it.
DEADLINE = 60 * 60


def manifest(port):
    here = f"http://127.0.0.1:{port}"
    return {
        "name": "Wingcord Reports",
        "url": "https://wingcord.app",
        "description": (
            "Publishes confirmed Wingcord bug reports and ideas as issues, "
            "and tells the Wingcord Discord server when they close."
        ),
        "hook_attributes": {"url": "https://reports.wingcord.app/github", "active": True},
        "redirect_url": f"{here}/created",
        "setup_url": f"{here}/installed",
        "setup_on_update": False,
        "public": False,
        "default_permissions": {"issues": "write", "metadata": "read"},
        "default_events": ["issues"],
    }


def page(title, body):
    return f"""<!doctype html><meta charset="utf-8"><title>{html.escape(title)}</title>
<style>body{{font:16px -apple-system,system-ui;margin:15vh auto;max-width:34em;padding:0 1em;line-height:1.5}}
button{{font:inherit;padding:.5em 1.2em}}</style>
<h1>{html.escape(title)}</h1>{body}""".encode()


def trade(code):
    """The App's settings for the one-time code (GitHub's "Create a GitHub App from a manifest")."""
    request = urllib.request.Request(
        f"https://api.github.com/app-manifests/{urllib.parse.quote(code)}/conversions",
        method="POST",
        headers={
            "Accept": "application/vnd.github+json",
            "X-GitHub-Api-Version": "2022-11-28",
            "User-Agent": "wingcord-reports-setup",
        },
    )
    with urllib.request.urlopen(request) as response:
        return json.load(response)


def hand_to_worker(app):
    """Both secrets in one request; wrangler reads them from stdin."""
    payload = json.dumps({
        "GITHUB_APP_PRIVATE_KEY": app["pem"],
        "GITHUB_WEBHOOK_SECRET": app["webhook_secret"],
    })
    result = subprocess.run(
        ["npx", "wrangler", "secret", "bulk"],
        input=payload, text=True, capture_output=True, cwd=WORKER,
    )
    if result.returncode != 0:
        # Wrangler's own words; they never hold the values.
        sys.stderr.write(result.stdout + result.stderr)
        return False
    return True


def write_client_id(client_id):
    text = WRANGLER_CONFIG.read_text()
    updated, count = re.subn(r'("GITHUB_APP_CLIENT_ID":\s*)"[^"]*"', rf'\g<1>"{client_id}"', text)
    if count != 1:
        return False
    WRANGLER_CONFIG.write_text(updated)
    return True


class Setup(BaseHTTPRequestHandler):
    state = secrets.token_urlsafe(24)
    done = False
    port = 0
    # Once the App is made, where to install it — a browser that comes back
    # to /created (a reload, a second request) is sent there, not to GitHub
    # again: the code is spent.
    install = None

    def log_message(self, *_):
        pass  # the query holds the one-time code

    def reply(self, status, body, location=None):
        self.send_response(status)
        if location:
            self.send_header("Location", location)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        url = urllib.parse.urlparse(self.path)
        query = urllib.parse.parse_qs(url.query)
        if url.path == "/":
            action = (f"https://github.com/organizations/{ORGANIZATION}/settings/apps/new"
                      f"?state={urllib.parse.quote(Setup.state)}")
            form = (f'<p>Opening GitHub with the App filled in…</p>'
                    f'<form id="f" method="post" action="{html.escape(action)}">'
                    f'<input type="hidden" name="manifest" value="{html.escape(json.dumps(manifest(Setup.port)))}">'
                    f'<button>Continue to GitHub</button></form>'
                    f'<script>document.getElementById("f").submit()</script>')
            return self.reply(200, page("Wingcord Reports", form))

        if url.path == "/created":
            if Setup.install:
                return self.reply(303, page("Made", ""), location=Setup.install)
            if query.get("state", [""])[0] != Setup.state or "code" not in query:
                return self.reply(400, page("That link isn't from this setup", "<p>Run the script again.</p>"))
            try:
                app = trade(query["code"][0])
            except urllib.error.HTTPError as error:
                print(f"GitHub refused the code ({error.code}). Run the script again.", file=sys.stderr)
                Setup.done = True
                return self.reply(502, page("GitHub refused the code", "<p>Run the script again.</p>"))
            print(f"Made the App: {app['name']} ({app['html_url']}), client ID {app['client_id']}.")
            if not hand_to_worker(app):
                print("The App exists, but its secrets didn't reach the Worker. On the App's page,\n"
                      "generate a new private key and set a new webhook secret, then put both with\n"
                      "`npx wrangler secret put` (README.md).", file=sys.stderr)
                Setup.done = True
                return self.reply(500, page("The secrets didn't reach the Worker",
                                            "<p>See the Terminal for what to do.</p>"))
            print("Its private key and webhook secret are Worker secrets now.")
            if write_client_id(app["client_id"]):
                print("Its client ID is in wrangler.jsonc.")
            else:
                print(f"Put its client ID in wrangler.jsonc by hand: GITHUB_APP_CLIENT_ID = {app['client_id']}")
            install = (f"https://github.com/apps/{urllib.parse.quote(app['slug'])}/installations/new/permissions"
                       f"?suggested_target_id={ORGANIZATION_ID}&repository_ids[]={REPOSITORY_ID}")
            Setup.install = install
            print(f"Next, in the browser: Install, on WingcordApp/wingcord only.\n  {install}")
            return self.reply(303, page("Made", f'<p><a href="{html.escape(install)}">Install it</a></p>'),
                              location=install)

        if url.path == "/installed":
            installation = query.get("installation_id", ["?"])[0]
            print(f"Installed (installation {installation}). All done.")
            Setup.done = True
            return self.reply(200, page("Installed", "<p>Wingcord Reports can open issues on "
                                                     "WingcordApp/wingcord. You can close this tab.</p>"))

        self.reply(404, page("Not here", ""))


def main():
    if '"GITHUB_APP_CLIENT_ID": ""' not in WRANGLER_CONFIG.read_text():
        print("wrangler.jsonc already has a client ID — the App seems made. To make it again, delete\n"
              "the old one on GitHub (WingcordApp ▸ Settings ▸ GitHub Apps) and empty that value.")
        sys.exit(1)
    server = HTTPServer(("127.0.0.1", 0), Setup)
    Setup.port = server.server_address[1]
    server.timeout = 5
    start = f"http://127.0.0.1:{Setup.port}/"
    print(f"Opening {start} — press Create GitHub App, then Install.")
    webbrowser.open(start)
    began = time.monotonic()
    while not Setup.done and time.monotonic() - began < DEADLINE:
        server.handle_request()
    server.server_close()
    if not Setup.done:
        print("Gave up after an hour; nothing was made unless GitHub said so above.")


if __name__ == "__main__":
    main()
