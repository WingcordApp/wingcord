// The index in D1: every statement the service makes, in one place.

import { LIMITS, type Area, type Caps, type IssueState, type Kind, type Origin, type Part, type Status } from "./config";
import { randomReportId } from "./crypto";
import type { ReportInput } from "./validate";

export interface ReportRow {
	id: string;
	kind: Kind;
	status: Status;
	area: Area;
	origin: Origin;
	summary: string | null;
	details: string | null;
	app_version: string;
	app_build: string;
	macos: string;
	model: string | null;
	chip: string | null;
	crash_kind: "crash" | "hang" | null;
	signal: string | null;
	fingerprint: string | null;
	frames: string | null;
	install: string | null;
	pending: string;
	bundle_size: number | null;
	screenshot_size: number | null;
	count: number;
	created_at: number;
	last_seen_at: number;
	inbox_message_id: string | null;
	inbox_claimed_at: number | null;
	issue_number: number | null;
	forum_post_id: string | null;
	closed_at: number | null;
	closed_by: string | null;
	/** Set while Publish… works on it (phase 7). */
	publishing_at: number | null;
	/** The Discord user who sent it from the pinned posts' form; null from the app. */
	reporter: string | null;
}

export interface RepeatRow {
	report_id: string;
	created_at: number;
	summary: string | null;
	details: string | null;
	app_version: string;
	app_build: string;
	macos: string;
	model: string | null;
}

/** The parts a report is still waiting for. */
export function pendingParts(report: Pick<ReportRow, "pending">): Part[] {
	return report.pending ? (report.pending.split(",") as Part[]) : [];
}

/** True once the inbox holds the report's message (not while it is being posted). */
export function isPosted(report: Pick<ReportRow, "inbox_message_id">): report is { inbox_message_id: string } {
	return report.inbox_message_id !== null && report.inbox_message_id !== "posting";
}

// MARK: Limits

export type Allowance = { allowed: true } | { allowed: false; reason: string; retryAfter: number };

/**
 * Counts this attempt against its install's hour and the service's day, and
 * says whether it is within both. The two counters move together in one
 * batch; an attempt over a limit is counted too, so a loop that ignores
 * the answer stays over it.
 */
export async function countAttempt(db: D1Database, install: string, now: number, caps: Caps): Promise<Allowance> {
	const hour = Math.floor(now / 3600);
	const hourEnd = (hour + 1) * 3600;
	const day = new Date(now * 1000).toISOString().slice(0, 10);
	const dayEnd = (Math.floor(now / 86400) + 1) * 86400;
	const upsert = `INSERT INTO counters (name, count, expires_at) VALUES (?1, 1, ?2)
		ON CONFLICT (name) DO UPDATE SET count = count + 1
		RETURNING count`;
	const [perInstall, perDay] = await db.batch<{ count: number }>([
		db.prepare(upsert).bind(`install:${install}:${hour}`, hourEnd),
		db.prepare(upsert).bind(`day:${day}`, dayEnd),
	]);
	if ((perInstall?.results[0]?.count ?? 0) > caps.installHourly) {
		return { allowed: false, reason: "too_many_from_this_mac", retryAfter: hourEnd - now };
	}
	if ((perDay?.results[0]?.count ?? 0) > caps.daily) {
		return { allowed: false, reason: "too_many_today", retryAfter: dayEnd - now };
	}
	return { allowed: true };
}

// MARK: Reports

export async function getReport(db: D1Database, id: string): Promise<ReportRow | null> {
	return db.prepare("SELECT * FROM reports WHERE id = ?1").bind(id).first<ReportRow>();
}

/** The open report for this crash in this build, if there is one. */
export async function findOpenCrash(db: D1Database, fingerprint: string, build: string): Promise<ReportRow | null> {
	return db
		.prepare(
			`SELECT * FROM reports
			WHERE fingerprint = ?1 AND app_build = ?2 AND status = 'open'
			ORDER BY created_at LIMIT 1`,
		)
		.bind(fingerprint, build)
		.first<ReportRow>();
}

/** Stores a new report under a fresh id and returns the id. `reporter` is a Discord user, for the forums' form. */
export async function insertReport(
	db: D1Database,
	input: ReportInput,
	keyHash: string,
	now: number,
	reporter: string | null = null,
): Promise<string> {
	for (let attempt = 0; attempt < 8; attempt++) {
		// Four characters hold a million ids; five after repeated collisions.
		const id = randomReportId(attempt < 5 ? 4 : 5);
		const inserted = await db
			.prepare(
				`INSERT INTO reports (
					id, kind, area, origin, summary, details, app_version, app_build, macos, model, chip,
					crash_kind, signal, fingerprint, frames, install, pending, created_at, last_seen_at, reporter
				) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15, ?16, ?17, ?18, ?18, ?19)
				ON CONFLICT (id) DO NOTHING
				RETURNING id`,
			)
			.bind(
				id,
				input.kind,
				input.area,
				input.origin,
				input.summary,
				input.details,
				input.appVersion,
				input.appBuild,
				input.macOS,
				input.model,
				input.chip,
				input.crash?.kind ?? null,
				input.crash?.signal ?? null,
				input.crash?.fingerprint ?? null,
				input.crash ? JSON.stringify(input.crash.frames) : null,
				input.install,
				input.attachments.join(","),
				now,
				reporter,
			)
			.first<{ id: string }>();
		if (!inserted) continue;
		await db
			.prepare("INSERT INTO keys (key_hash, report_id, uploads, created_at) VALUES (?1, ?2, 1, ?3)")
			.bind(keyHash, id, now)
			.run();
		return id;
	}
	throw new Error("no free report id after 8 attempts");
}

/** Counts a repeat of an open crash into its report, keeping the sender's words. */
export async function addRepeat(
	db: D1Database,
	id: string,
	input: ReportInput,
	keyHash: string,
	now: number,
): Promise<ReportRow> {
	await db.batch([
		db.prepare("UPDATE reports SET count = count + 1, last_seen_at = ?2 WHERE id = ?1").bind(id, now),
		db
			.prepare(
				`INSERT INTO repeats (report_id, created_at, summary, details, app_version, app_build, macos, model, install)
				VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9)`,
			)
			.bind(id, now, input.summary, input.details, input.appVersion, input.appBuild, input.macOS, input.model, input.install),
		db
			.prepare("INSERT INTO keys (key_hash, report_id, uploads, created_at) VALUES (?1, ?2, 0, ?3)")
			.bind(keyHash, id, now),
	]);
	const report = await getReport(db, id);
	if (!report) throw new Error("report vanished while counting a repeat");
	return report;
}

export async function latestRepeat(db: D1Database, id: string): Promise<RepeatRow | null> {
	return db
		.prepare(
			`SELECT report_id, created_at, summary, details, app_version, app_build, macos, model
			FROM repeats WHERE report_id = ?1 ORDER BY created_at DESC LIMIT 1`,
		)
		.bind(id)
		.first<RepeatRow>();
}

/** The report a key opens, and whether that key may upload its parts. */
export async function reportForKey(
	db: D1Database,
	keyHash: string,
): Promise<{ report: ReportRow; uploads: boolean } | null> {
	const row = await db
		.prepare(
			`SELECT reports.*, keys.uploads AS key_uploads
			FROM keys JOIN reports ON reports.id = keys.report_id
			WHERE keys.key_hash = ?1`,
		)
		.bind(keyHash)
		.first<ReportRow & { key_uploads: number }>();
	if (!row) return null;
	const { key_uploads, ...report } = row;
	return { report, uploads: key_uploads === 1 };
}

/**
 * Marks `part` arrived. Returns what is still pending and the inbox message,
 * or null when the part was not expected (already in, or never announced).
 * One statement, so two parts finishing at once cannot both see "done".
 */
export async function completePart(
	db: D1Database,
	id: string,
	part: Part,
	size: number,
): Promise<{ pending: string; inbox_message_id: string | null } | null> {
	return db
		.prepare(
			`UPDATE reports SET
				pending = trim(replace(',' || pending || ',', ',' || ?2 || ',', ','), ','),
				bundle_size = CASE WHEN ?2 = 'bundle' THEN ?3 ELSE bundle_size END,
				screenshot_size = CASE WHEN ?2 = 'screenshot' THEN ?3 ELSE screenshot_size END
			WHERE id = ?1 AND instr(',' || pending || ',', ',' || ?2 || ',') > 0
			RETURNING pending, inbox_message_id`,
		)
		.bind(id, part, size)
		.first<{ pending: string; inbox_message_id: string | null }>();
}

/** Stops waiting for `part`: it is not coming. Returns what is still pending, as `completePart` does. */
export async function dropPart(db: D1Database, id: string, part: Part): Promise<{ pending: string } | null> {
	return db
		.prepare(
			`UPDATE reports SET pending = trim(replace(',' || pending || ',', ',' || ?2 || ',', ','), ',')
			WHERE id = ?1 AND instr(',' || pending || ',', ',' || ?2 || ',') > 0
			RETURNING pending`,
		)
		.bind(id, part)
		.first<{ pending: string }>();
}

export async function solveReport(db: D1Database, id: string, now: number, by: string): Promise<boolean> {
	const changed = await db
		.prepare(
			`UPDATE reports SET status = 'solved', closed_at = ?2, closed_by = ?3
			WHERE id = ?1 AND status = 'open'
			RETURNING id`,
		)
		.bind(id, now, by)
		.first<{ id: string }>();
	return changed !== null;
}

// MARK: The inbox's claim

/**
 * Claims the right to post a report's inbox message, so the upload that
 * completes it and the cron never both post. A claim left by a Worker that
 * died mid-post is taken over after `LIMITS.inboxClaimSeconds`.
 */
export async function claimInbox(db: D1Database, id: string, now: number): Promise<boolean> {
	const claimed = await db
		.prepare(
			`UPDATE reports SET inbox_message_id = 'posting', inbox_claimed_at = ?2
			WHERE id = ?1 AND (inbox_message_id IS NULL
				OR (inbox_message_id = 'posting' AND inbox_claimed_at < ?3))
			RETURNING id`,
		)
		.bind(id, now, now - LIMITS.inboxClaimSeconds)
		.first<{ id: string }>();
	return claimed !== null;
}

export async function setInbox(db: D1Database, id: string, messageId: string): Promise<void> {
	await db.prepare("UPDATE reports SET inbox_message_id = ?2 WHERE id = ?1").bind(id, messageId).run();
}

export async function releaseInbox(db: D1Database, id: string): Promise<void> {
	await db
		.prepare("UPDATE reports SET inbox_message_id = NULL WHERE id = ?1 AND inbox_message_id = 'posting'")
		.bind(id)
		.run();
}

/** Reports the inbox has not had: complete, or past the parts' grace period. */
export async function unposted(db: D1Database, now: number, limit: number): Promise<string[]> {
	const rows = await db
		.prepare(
			`SELECT id FROM reports
			WHERE (inbox_message_id IS NULL OR (inbox_message_id = 'posting' AND inbox_claimed_at < ?2))
				AND (pending = '' OR created_at < ?1)
			ORDER BY created_at LIMIT ?3`,
		)
		.bind(now - LIMITS.partsGraceSeconds, now - LIMITS.inboxClaimSeconds, limit)
		.all<{ id: string }>();
	return rows.results.map((row) => row.id);
}

// MARK: Retention

export interface Expired {
	/** Deleted outright. */
	removed: string[];
	/** Published: kept, minus everything private. */
	stripped: string[];
}

/**
 * The 90-day rule: an unpublished report goes entirely; a published one
 * keeps only its id, status and links, so GitHub's events still find it.
 * Expired counters go too.
 */
export async function expire(db: D1Database, now: number, limit: number): Promise<Expired> {
	const cutoff = now - LIMITS.retentionDays * 86400;
	const rows = await db
		.prepare("SELECT id, status FROM reports WHERE created_at < ?1 AND (install IS NOT NULL OR status IN ('open', 'solved')) LIMIT ?2")
		.bind(cutoff, limit)
		.all<{ id: string; status: Status }>();
	const removed = rows.results.filter((row) => row.status === "open" || row.status === "solved").map((row) => row.id);
	const stripped = rows.results.filter((row) => !removed.includes(row.id)).map((row) => row.id);

	const statements: D1PreparedStatement[] = [];
	for (const id of removed) {
		statements.push(db.prepare("DELETE FROM repeats WHERE report_id = ?1").bind(id));
		statements.push(db.prepare("DELETE FROM keys WHERE report_id = ?1").bind(id));
		statements.push(db.prepare("DELETE FROM reports WHERE id = ?1").bind(id));
	}
	for (const id of stripped) {
		statements.push(db.prepare("DELETE FROM repeats WHERE report_id = ?1").bind(id));
		statements.push(
			db
				.prepare(
					`UPDATE reports SET summary = NULL, details = NULL, frames = NULL, install = NULL,
					model = NULL, chip = NULL, bundle_size = NULL, screenshot_size = NULL, reporter = NULL
					WHERE id = ?1`,
				)
				.bind(id),
		);
	}
	statements.push(db.prepare("DELETE FROM counters WHERE expires_at < ?1").bind(now));
	await db.batch(statements);
	return { removed, stripped };
}

// MARK: Published issues (phase 7)

/** One version and Mac a published report was seen on — public (D26). */
export interface Sighting {
	/** `1.0 (42)`; empty when the sender didn't say (the forums' form). */
	app: string;
	macos: string;
	/** `Mac17,2`, when known. */
	mac: string | null;
}

export interface IssueRow {
	number: number;
	kind: Kind;
	crash: number;
	area: Area;
	title: string;
	body: string;
	details: string | null;
	first_report: string;
	origin: Origin;
	screenshot: number;
	forum_post_id: string | null;
	linked: number;
	state: IssueState;
	/** The state the forum post last showed. */
	post_state: IssueState;
	planned: number;
	count: number;
	/** JSON: `Sighting[]`. */
	seen: string;
	created_at: number;
	updated_at: number;
}

export function sightings(issue: Pick<IssueRow, "seen">): Sighting[] {
	try {
		const parsed = JSON.parse(issue.seen) as unknown;
		return Array.isArray(parsed) ? (parsed as Sighting[]) : [];
	} catch {
		return [];
	}
}

/** A report's own Mac and those of its repeats, oldest first. */
export async function reportSightings(db: D1Database, report: ReportRow): Promise<Sighting[]> {
	const rows = await db
		.prepare("SELECT app_version, app_build, macos, model FROM repeats WHERE report_id = ?1 ORDER BY created_at")
		.bind(report.id)
		.all<Pick<RepeatRow, "app_version" | "app_build" | "macos" | "model">>();
	return [report, ...rows.results].map((row) => ({
		app: row.app_version ? `${row.app_version}${row.app_build ? ` (${row.app_build})` : ""}` : "",
		macos: row.macos,
		mac: row.model,
	}));
}

/** `seen` and `more` together, each once, the newest kept when there are too many. */
export function mergeSightings(seen: Sighting[], more: Sighting[]): Sighting[] {
	const key = (sighting: Sighting) => `${sighting.app}|${sighting.macos}|${sighting.mac ?? ""}`;
	const merged = new Map<string, Sighting>();
	for (const sighting of [...seen, ...more]) {
		if (!sighting.app && !sighting.macos) continue;
		merged.delete(key(sighting));
		merged.set(key(sighting), sighting);
	}
	return [...merged.values()].slice(-LIMITS.seen);
}

export async function getIssue(db: D1Database, number: number): Promise<IssueRow | null> {
	return db.prepare("SELECT * FROM issues WHERE number = ?1").bind(number).first<IssueRow>();
}

/** The open issues, the most recently changed first — what Same as… offers. */
export async function openIssues(db: D1Database, limit: number): Promise<IssueRow[]> {
	const rows = await db
		.prepare("SELECT * FROM issues WHERE state = 'open' ORDER BY updated_at DESC LIMIT ?1")
		.bind(limit)
		.all<IssueRow>();
	return rows.results;
}

/** Issues already holding a report of this crash. */
export async function issuesWithCrash(db: D1Database, fingerprint: string): Promise<number[]> {
	const rows = await db
		.prepare(
			`SELECT DISTINCT issue_number FROM reports
			WHERE fingerprint = ?1 AND issue_number IS NOT NULL`,
		)
		.bind(fingerprint)
		.all<{ issue_number: number }>();
	return rows.results.map((row) => row.issue_number);
}

/**
 * Holds an open report for Publish…, so a second press can't make a second
 * issue. A hold left by a Worker that died mid-way lapses after
 * `LIMITS.publishClaimSeconds`.
 */
export async function claimPublishing(db: D1Database, id: string, now: number): Promise<ReportRow | null> {
	return db
		.prepare(
			`UPDATE reports SET publishing_at = ?2
			WHERE id = ?1 AND status = 'open' AND (publishing_at IS NULL OR publishing_at < ?3)
			RETURNING *`,
		)
		.bind(id, now, now - LIMITS.publishClaimSeconds)
		.first<ReportRow>();
}

export async function releasePublishing(db: D1Database, id: string): Promise<void> {
	await db.prepare("UPDATE reports SET publishing_at = NULL WHERE id = ?1").bind(id).run();
}

/** The issue GitHub just made, and its report pointing at it — at once, so a retry never makes another. */
export async function recordIssue(db: D1Database, issue: IssueRow, reportId: string): Promise<void> {
	await db.batch([
		db
			.prepare(
				`INSERT INTO issues (
					number, kind, crash, area, title, body, details, first_report, origin, screenshot,
					forum_post_id, linked, state, post_state, planned, count, seen, created_at, updated_at
				) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15, ?16, ?17, ?18, ?19)`,
			)
			.bind(
				issue.number,
				issue.kind,
				issue.crash,
				issue.area,
				issue.title,
				issue.body,
				issue.details,
				issue.first_report,
				issue.origin,
				issue.screenshot,
				issue.forum_post_id,
				issue.linked,
				issue.state,
				issue.post_state,
				issue.planned,
				issue.count,
				issue.seen,
				issue.created_at,
				issue.updated_at,
			),
		db.prepare("UPDATE reports SET issue_number = ?2 WHERE id = ?1").bind(reportId, issue.number),
	]);
}

export async function setForumPost(db: D1Database, number: number, postId: string, now: number): Promise<void> {
	await db
		.prepare("UPDATE issues SET forum_post_id = ?2, updated_at = ?3 WHERE number = ?1")
		.bind(number, postId, now)
		.run();
}

export async function setLinked(db: D1Database, number: number): Promise<void> {
	await db.prepare("UPDATE issues SET linked = 1 WHERE number = ?1").bind(number).run();
}

/** The last step of publishing: the report is out. */
export async function markPublished(db: D1Database, id: string): Promise<void> {
	await db
		.prepare("UPDATE reports SET status = 'published', publishing_at = NULL WHERE id = ?1 AND status = 'open'")
		.bind(id)
		.run();
}

/**
 * Same as…: counts an open, unpublished report into an open issue. Returns
 * the issue as it now stands, or null when either has moved on meanwhile.
 */
export async function countInto(
	db: D1Database,
	report: ReportRow,
	issue: IssueRow,
	seen: Sighting[],
	now: number,
): Promise<IssueRow | null> {
	const claimed = await db
		.prepare(
			`UPDATE reports SET status = 'published', issue_number = ?2, publishing_at = NULL
			WHERE id = ?1 AND status = 'open' AND issue_number IS NULL
				AND (publishing_at IS NULL OR publishing_at < ?3)
			RETURNING id`,
		)
		.bind(report.id, issue.number, now - LIMITS.publishClaimSeconds)
		.first<{ id: string }>();
	if (!claimed) return null;
	return db
		.prepare(
			`UPDATE issues SET count = count + ?2, seen = ?3, updated_at = ?4
			WHERE number = ?1
			RETURNING *`,
		)
		.bind(issue.number, report.count, JSON.stringify(seen), now)
		.first<IssueRow>();
}

/**
 * Moves an issue to `state` — once: the change is made only if it is a
 * change, so GitHub's event for a close the inbox made itself, or the same
 * event delivered twice, finds nothing to do.
 */
export async function claimIssueState(
	db: D1Database,
	number: number,
	state: IssueState,
	now: number,
): Promise<{ issue: IssueRow; previous: IssueState } | null> {
	const before = await getIssue(db, number);
	if (!before || before.state === state) return null;
	const issue = await db
		.prepare("UPDATE issues SET state = ?2, updated_at = ?3 WHERE number = ?1 AND state = ?4 RETURNING *")
		.bind(number, state, now, before.state)
		.first<IssueRow>();
	return issue ? { issue, previous: before.state } : null;
}

/**
 * Claims showing `state` on the issue's post: returns the state it showed
 * before, or null when it shows `state` already (or someone else is showing
 * it right now). A change that fails is handed back with `setPostState`.
 */
export async function claimPostState(db: D1Database, number: number, state: IssueState): Promise<IssueState | null> {
	const before = await db
		.prepare("SELECT post_state FROM issues WHERE number = ?1")
		.bind(number)
		.first<{ post_state: IssueState }>();
	if (!before || before.post_state === state) return null;
	const claimed = await db
		.prepare("UPDATE issues SET post_state = ?2 WHERE number = ?1 AND post_state = ?3 RETURNING number")
		.bind(number, state, before.post_state)
		.first<{ number: number }>();
	return claimed ? before.post_state : null;
}

export async function setPostState(db: D1Database, number: number, state: IssueState): Promise<void> {
	await db.prepare("UPDATE issues SET post_state = ?2 WHERE number = ?1").bind(number, state).run();
}

/** The reports counted into a closed issue: closed with it, their files about to be deleted. */
export async function closeReports(
	db: D1Database,
	number: number,
	status: Status,
	now: number,
	by: string | null,
): Promise<string[]> {
	const rows = await db
		.prepare(
			`UPDATE reports SET status = ?2, closed_at = ?3, closed_by = ?4, bundle_size = NULL,
				screenshot_size = NULL, publishing_at = NULL
			WHERE issue_number = ?1 AND status IN ('open', 'published', 'fixed', 'wontfix')
			RETURNING id`,
		)
		.bind(number, status, now, by)
		.all<{ id: string }>();
	return rows.results.map((row) => row.id);
}

/** A reopened issue's reports are published again; their files stay deleted. */
export async function reopenReports(db: D1Database, number: number): Promise<void> {
	await db
		.prepare(
			`UPDATE reports SET status = 'published', closed_at = NULL, closed_by = NULL
			WHERE issue_number = ?1 AND status IN ('fixed', 'wontfix')`,
		)
		.bind(number)
		.run();
}

/** The `planned` label came or went. Null when nothing changed. */
export async function setPlanned(db: D1Database, number: number, planned: boolean, now: number): Promise<IssueRow | null> {
	return db
		.prepare("UPDATE issues SET planned = ?2, updated_at = ?3 WHERE number = ?1 AND planned != ?2 RETURNING *")
		.bind(number, planned ? 1 : 0, now)
		.first<IssueRow>();
}

/** The issue was renamed on GitHub. Null when nothing changed. */
export async function renameIssue(db: D1Database, number: number, title: string, now: number): Promise<IssueRow | null> {
	return db
		.prepare("UPDATE issues SET title = ?2, updated_at = ?3 WHERE number = ?1 AND title != ?2 RETURNING *")
		.bind(number, title, now)
		.first<IssueRow>();
}

/**
 * An issue gone from GitHub, deleted or moved to another repository: its
 * reports let go of it and its row is deleted, in one batch. Reports still
 * waiting on it are open again, so the inbox offers Publish… and Same as…
 * for them once more. Closed ones keep their verdict and only lose the link.
 * Returns the reports it let go.
 */
export async function forgetIssue(db: D1Database, number: number): Promise<ReportRow[]> {
	// SQLite evaluates every SET expression against the row as it was, so each CASE reads the old status.
	const [freed] = await db.batch<ReportRow>([
		db
			.prepare(
				`UPDATE reports SET issue_number = NULL, publishing_at = NULL,
					status = CASE WHEN status = 'published' THEN 'open' ELSE status END,
					closed_at = CASE WHEN status = 'published' THEN NULL ELSE closed_at END,
					closed_by = CASE WHEN status = 'published' THEN NULL ELSE closed_by END
				WHERE issue_number = ?1
				RETURNING *`,
			)
			.bind(number),
		db.prepare("DELETE FROM issues WHERE number = ?1").bind(number),
	]);
	return freed?.results ?? [];
}

/** The newest reports counted into an issue, for redrawing their inbox messages. */
export async function reportsForIssue(db: D1Database, number: number, limit: number): Promise<ReportRow[]> {
	const rows = await db
		.prepare("SELECT * FROM reports WHERE issue_number = ?1 ORDER BY created_at DESC LIMIT ?2")
		.bind(number, limit)
		.all<ReportRow>();
	return rows.results;
}
