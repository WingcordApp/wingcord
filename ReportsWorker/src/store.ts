// The index in D1: every statement the service makes, in one place.

import { LIMITS, type Area, type Caps, type Kind, type Origin, type Part, type Status } from "./config";
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

/** Stores a new report under a fresh id and returns the id. */
export async function insertReport(db: D1Database, input: ReportInput, keyHash: string, now: number): Promise<string> {
	for (let attempt = 0; attempt < 8; attempt++) {
		// Four characters hold a million ids; five after repeated collisions.
		const id = randomReportId(attempt < 5 ? 4 : 5);
		const inserted = await db
			.prepare(
				`INSERT INTO reports (
					id, kind, area, origin, summary, details, app_version, app_build, macos, model, chip,
					crash_kind, signal, fingerprint, frames, install, pending, created_at, last_seen_at
				) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15, ?16, ?17, ?18, ?18)
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
					model = NULL, chip = NULL, bundle_size = NULL, screenshot_size = NULL
					WHERE id = ?1`,
				)
				.bind(id),
		);
	}
	statements.push(db.prepare("DELETE FROM counters WHERE expires_at < ?1").bind(now));
	await db.batch(statements);
	return { removed, stripped };
}
