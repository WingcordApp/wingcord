-- Wingcord's reports index (docs/BUG-REPORTING.md §9).
--
-- Times are Unix seconds. The tester's words, the crash's frames and the
-- install live here only until the report is solved or 90 days pass; a
-- published report keeps only what links it to GitHub and the forum.

CREATE TABLE reports (
	id TEXT PRIMARY KEY,                       -- WC-4F2K
	kind TEXT NOT NULL CHECK (kind IN ('bug', 'idea')),
	status TEXT NOT NULL DEFAULT 'open'
		CHECK (status IN ('open', 'solved', 'published', 'fixed', 'wontfix')),
	area TEXT NOT NULL,
	origin TEXT NOT NULL,
	summary TEXT,                              -- what happened / the idea
	details TEXT,                              -- steps / how they would use it
	app_version TEXT NOT NULL,
	app_build TEXT NOT NULL,
	macos TEXT NOT NULL,
	model TEXT,
	chip TEXT,
	crash_kind TEXT CHECK (crash_kind IN ('crash', 'hang')),
	signal TEXT,
	fingerprint TEXT,
	frames TEXT,                               -- JSON array of strings
	install TEXT,                              -- derived one way from the install's salt
	pending TEXT NOT NULL DEFAULT '',          -- parts still to arrive: 'bundle,screenshot'
	bundle_size INTEGER,
	screenshot_size INTEGER,
	count INTEGER NOT NULL DEFAULT 1,
	created_at INTEGER NOT NULL,
	last_seen_at INTEGER NOT NULL,
	inbox_message_id TEXT,                     -- NULL, 'posting', or the message's id
	inbox_claimed_at INTEGER,
	issue_number INTEGER,                      -- phase 7
	forum_post_id TEXT,                        -- phase 7
	closed_at INTEGER,
	closed_by TEXT                             -- the Discord user who closed it
);

-- One open report per crash: a repeat is counted into it.
CREATE INDEX reports_open_crash ON reports (fingerprint, app_build)
	WHERE status = 'open' AND fingerprint IS NOT NULL;
CREATE INDEX reports_created ON reports (created_at);
CREATE INDEX reports_unposted ON reports (created_at)
	WHERE inbox_message_id IS NULL OR inbox_message_id = 'posting';

-- Each sender's key, hashed: the first sender (who uploads the parts) and
-- everyone whose crash was counted into the report since.
CREATE TABLE keys (
	key_hash TEXT PRIMARY KEY,
	report_id TEXT NOT NULL,
	uploads INTEGER NOT NULL DEFAULT 0,
	created_at INTEGER NOT NULL
);
CREATE INDEX keys_report ON keys (report_id);

-- The words and Mac of each later sender of the same crash.
CREATE TABLE repeats (
	report_id TEXT NOT NULL,
	created_at INTEGER NOT NULL,
	summary TEXT,
	details TEXT,
	app_version TEXT NOT NULL,
	app_build TEXT NOT NULL,
	macos TEXT NOT NULL,
	model TEXT,
	install TEXT
);
CREATE INDEX repeats_report ON repeats (report_id, created_at);

-- The exact limits: 'install:<id>:<hour>' and 'day:<yyyy-mm-dd>'.
CREATE TABLE counters (
	name TEXT PRIMARY KEY,
	count INTEGER NOT NULL,
	expires_at INTEGER NOT NULL
);
