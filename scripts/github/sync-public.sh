#!/bin/bash
# Copies the public tracker's own files from this repository to
# WingcordApp/wingcord (docs/BUG-REPORTING.md D38): the issue forms, the triage
# workflow and CodeRabbit's settings. Makes one commit there, signed
# arkanalex <alex@wingcord.app>, shows it — and pushes only with --push.
# Run scripts/github/labels.sh first: the forms and CodeRabbit name its labels.
#
#   scripts/github/sync-public.sh           make the commit and show it
#   scripts/github/sync-public.sh --push    …and push it
#
# Only these files go; nothing else of this repository is read. (The code goes
# public through scripts/public-mirror/ instead, once its blockers are cleared.)
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# Retired by the code's first publish (docs/BUG-REPORTING.md §14): these files
# travel with the public copy now, and a commit made there on its own would
# keep the next sync from being a fast-forward.
if [[ -s "$ROOT/scripts/public-mirror/frozen.sha256" ]]; then
    echo "Retired: the public copy carries these files now (docs/BUG-REPORTING.md §14)." >&2
    exit 1
fi
WORK="$(mktemp -d)/wingcord"
FILES=(
    .github/ISSUE_TEMPLATE/bug_report.yml
    .github/ISSUE_TEMPLATE/feature_idea.yml
    .github/ISSUE_TEMPLATE/config.yml
    .github/workflows/issue-triage.yml
    .coderabbit.yaml
)

gh repo clone WingcordApp/wingcord "$WORK" -- --quiet
for file in "${FILES[@]}"; do
    mkdir -p "$WORK/$(dirname "$file")"
    cp "$ROOT/$file" "$WORK/$file"
done
cd "$WORK"
git add -A
if git diff --cached --quiet; then
    echo "WingcordApp/wingcord has these files already."
    exit 0
fi
# Like the public mirror's history: no session links.
git -c user.name=arkanalex -c user.email=alex@wingcord.app commit --quiet -F - <<'MESSAGE'
Issues sorted as they come in: the forms ask where in Wingcord and how much it gets in the way, a workflow labels the area and `needs triage`, and CodeRabbit sets a bug's priority and points out duplicates

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
MESSAGE
git show --stat --format='%h %an <%ae>%n%n%B' HEAD
if [[ "${1:-}" == "--push" ]]; then
    git push --quiet origin HEAD
    echo "Pushed to WingcordApp/wingcord."
else
    echo "Not pushed. Run again with --push to send it."
fi
