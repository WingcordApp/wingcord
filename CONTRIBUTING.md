# Contributing to Wingcord

Pull requests are welcome. For anything bigger than a small fix, open an issue first or comment on an existing one, so we can agree on the approach before you put time into it.

If you found a bug, report it from inside Wingcord when you can: **Help > Report a Bug…**, or `/bug` in any message box. The report carries the logs and system details needed to track it down, and you can look at every file before it's sent.

## How pull requests are merged

Pull requests are reviewed and merged here, on GitHub. Your name and email stay on your commits as the author, and they become public with them. If you'd rather not publish your email address, commit with your GitHub no-reply address ([Setting your commit email address](https://docs.github.com/en/account-and-profile/setting-up-and-managing-your-personal-account-on-github/managing-email-preferences/setting-your-commit-email-address) explains how).

A few things make this go smoothly:

- Base your branch on the latest `main`. If `main` moves on, rebase onto it instead of merging it into your branch.
- Keep each pull request to one change. Several small commits are fine; they may be squashed into one, and you stay its author.
- Say in the commit message what changed and why.

## Building and testing

You need macOS 27 and Xcode with Swift 6.4. `scripts/run-demo.sh` builds a debug copy that runs on sample data without a Discord account, which is the easiest way to try a change and take screenshots of it.

Run the tests before you open the pull request:

```sh
swift test
swift test --package-path Packages/WingcordCore
swift test --package-path Packages/WingcordNet
swift test --package-path Packages/WingcordVoice
```

If you changed the reports service in `ReportsWorker/`, run its checks as well (they need Node 26):

```sh
cd ReportsWorker
npm ci
npm run check
npm test
```

Tests run in parallel and share one `AppSettings.shared`. A test that changes a setting, or depends on one, does it inside `withAppSettings` (in `Tests/WingcordTests/AppSettingsIsolation.swift`) and names every setting it touches: it puts them back afterwards and keeps other such tests from running in between. Where the code under test takes the settings as a parameter, give it an `AppSettings` of its own on a throwaway `UserDefaults` suite instead. `AppSettingsRuleTests` fails on any other way of changing them.

Match the style of the code around your change. There's no formatter to run. Comments that point to `docs/` refer to the maintainer's design notes, which aren't published.

## Keep real data out

Tests, fixtures and screenshots must not contain real Discord data: user, server or channel ids, usernames, messages, invite links or tokens. Make up values instead, as the existing fixtures do, and leave out anything personal about yourself too.

## Security problems

Please don't report a security problem in a public issue. Use **Report a vulnerability** on this repository's [Security tab](https://github.com/WingcordApp/wingcord/security/advisories/new) instead, which reaches the developer privately.

## License

Wingcord is free software under the GNU General Public License, version 3 or any later version. By opening a pull request, you agree that your contribution is licensed the same way.
