-- Phase 7: publishing (docs/BUG-REPORTING.md D26, D27, D30–D37).
--
-- One row per GitHub issue the inbox published. Everything in it is public
-- already — on GitHub and in the forum — so it is kept past the 90-day rule;
-- the reports counted into an issue point at it by `reports.issue_number`.
CREATE TABLE issues (
	number INTEGER PRIMARY KEY,                -- the issue on GitHub
	kind TEXT NOT NULL CHECK (kind IN ('bug', 'idea')),
	crash INTEGER NOT NULL DEFAULT 0,          -- a crash or a freeze: labelled `crash`, tagged Crash
	area TEXT NOT NULL,
	title TEXT NOT NULL,                       -- as published; GitHub's renames follow
	body TEXT NOT NULL,                        -- the words, as published
	details TEXT,                              -- steps, or how it would be used
	first_report TEXT NOT NULL,                -- the report it was published from
	origin TEXT NOT NULL,                      -- that report's origin
	screenshot INTEGER NOT NULL DEFAULT 0,     -- the tester's picture went with it
	forum_post_id TEXT,                        -- NULL until the post exists
	linked INTEGER NOT NULL DEFAULT 0,         -- the issue links to the post
	state TEXT NOT NULL DEFAULT 'open'
		CHECK (state IN ('open', 'fixed', 'wontfix', 'duplicate')),
	post_state TEXT NOT NULL DEFAULT 'open',   -- the state the post last showed: a failed change is tried again
	planned INTEGER NOT NULL DEFAULT 0,
	count INTEGER NOT NULL DEFAULT 1,          -- reports counted into it, repeats included
	seen TEXT NOT NULL DEFAULT '[]',           -- JSON: [{ app, macos, mac }], the versions and Macs
	created_at INTEGER NOT NULL,
	updated_at INTEGER NOT NULL
);
CREATE INDEX issues_open ON issues (updated_at) WHERE state = 'open';

-- The reports counted into each issue.
CREATE INDEX reports_issue ON reports (issue_number) WHERE issue_number IS NOT NULL;

-- A press of Publish… holds its report while it works, so a second press
-- can't make a second issue.
ALTER TABLE reports ADD COLUMN publishing_at INTEGER;

-- Who sent a report from the pinned posts' form: a Discord user id, shown in
-- the private inbox only. NULL for the app's reports.
ALTER TABLE reports ADD COLUMN reporter TEXT;
