// The inbox message: one per report, in the private channel, from the bot.
//
// **Nothing a tester typed can ping, link or format.** Their words go in the
// embed (embeds never unfurl links) with every Markdown character escaped —
// so `[x](url)` is not a link, `<@id>` not a mention, `https://` not even
// clickable — and every message carries `allowed_mentions: { parse: [] }`.

import { AREA_TITLES, LIMITS, type IssueState, type Origin } from "./config";
import { pendingParts, type RepeatRow, type ReportRow } from "./store";

/** Where a published report lives (phase 7). */
export interface Published {
	number: number;
	state: IssueState;
	issueUrl: string;
	/** Null while the post is still to be made. */
	postUrl: string | null;
}

export interface Embed {
	title: string;
	description?: string;
	color: number;
	fields: { name: string; value: string; inline?: boolean }[];
	footer?: { text: string };
	timestamp?: string;
	/** A picture in the card — `attachment://<name>` for a file sent with the message. */
	image?: { url: string };
}

export interface Button {
	type: 2;
	style: 1 | 2 | 3 | 4;
	label: string;
	custom_id: string;
	disabled?: boolean;
}

export interface MessageBody {
	content: string;
	embeds: Embed[];
	components: { type: 1; components: Button[] }[];
	allowed_mentions: { parse: [] };
}

type Variant = "bug" | "crash" | "hang" | "idea";

const MARKS: Record<Variant, string> = { bug: "🐞", crash: "💥", hang: "🧊", idea: "💡" };

const COLORS: Record<Variant | "closed", number> = {
	bug: 0x5865f2,
	crash: 0xed4245,
	hang: 0xf0b132,
	idea: 0xfee75c,
	closed: 0x80848e,
};

function variant(report: ReportRow): Variant {
	if (report.kind === "idea") return "idea";
	return report.crash_kind ?? "bug";
}

export function inboxMessage(
	report: ReportRow,
	latest: RepeatRow | null,
	now: number,
	published: Published | null = null,
): MessageBody {
	const kind = variant(report);
	const open = report.status === "open";
	// Open on GitHub, whether the inbox finished publishing or not.
	const live = published !== null && published.state === "open" && (open || report.status === "published");
	const fields: Embed["fields"] = [];

	if (report.details) {
		fields.push({
			name: report.kind === "idea" ? "How they'd use it" : "Steps",
			value: clip(escapeMarkdown(report.details), 1000),
		});
	}
	if (report.crash_kind) fields.push({ name: kind === "hang" ? "Freeze" : "Crash", value: crashText(report) });
	fields.push({ name: "Mac", value: macText(report) });
	if (report.reporter) fields.push({ name: "Sent by", value: `<@${report.reporter}>`, inline: true });
	fields.push({ name: "Files", value: filesText(report, now) });
	if (report.count > 1) fields.push({ name: `Seen ${report.count} times`, value: repeatText(report, latest) });
	if (published) fields.push({ name: "Published", value: publishedText(report, published) });
	if (!open) fields.push({ name: "Status", value: statusText(report, published) });

	const buttons: Button[] = [];
	const hasFiles = report.bundle_size !== null || report.screenshot_size !== null;
	if (open && report.issue_number === null) {
		buttons.push({ type: 2, style: 1, label: "Publish…", custom_id: `publish:${report.id}` });
		buttons.push({ type: 2, style: 2, label: "Same as…", custom_id: `same:${report.id}` });
	} else if (open && live) {
		// The issue was made and something after it failed: the press makes only what's missing.
		buttons.push({ type: 2, style: 1, label: "Finish Publishing", custom_id: `publish:${report.id}` });
	}
	if (open || live) {
		buttons.push({ type: 2, style: 2, label: "Download", custom_id: `download:${report.id}`, disabled: !hasFiles });
		// On a published report, Solve closes its issue (D27).
		buttons.push({ type: 2, style: 3, label: "Solve", custom_id: `solve:${report.id}` });
	}

	return {
		content: "",
		embeds: [
			{
				title: `${MARKS[kind]} ${report.id} · ${AREA_TITLES[report.area]}`,
				description: report.summary ? clip(escapeMarkdown(report.summary), 1500) : "*No words left — expired.*",
				color: open || live ? COLORS[kind] : COLORS.closed,
				fields,
				footer: { text: originText(report.origin, report.kind) },
				timestamp: new Date(report.created_at * 1000).toISOString(),
			},
		],
		components: buttons.length ? [{ type: 1, components: buttons }] : [],
		allowed_mentions: { parse: [] },
	};
}

function macText(report: Pick<ReportRow, "app_version" | "app_build" | "macos" | "model" | "chip">): string {
	// The forums' form leaves the versions to the sender, who may not give them.
	const parts = [
		report.app_version
			? `Wingcord ${report.app_version}${report.app_build ? ` (${report.app_build})` : ""}`
			: "Wingcord version not given",
	];
	if (report.macos) parts.push(`macOS ${report.macos}`);
	if (report.model) parts.push(report.model);
	if (report.chip) parts.push(report.chip);
	return parts.join(" · ");
}

function crashText(report: ReportRow): string {
	const head = report.signal ?? (report.crash_kind === "hang" ? "Stopped answering" : "Crashed");
	let frames: string[] = [];
	try {
		frames = report.frames ? (JSON.parse(report.frames) as string[]) : [];
	} catch {
		frames = [];
	}
	if (frames.length === 0) return head;
	// Frames are printable ASCII (validate.ts); a backtick could still end the block.
	const block = frames.map((frame) => frame.replaceAll("`", "'")).join("\n");
	return clip(`${head}\n\`\`\`\n${block}\n\`\`\``, 1000, "\n```");
}

function filesText(report: ReportRow, now: number): string {
	if (report.status !== "open" && report.status !== "published") return "Deleted when it was closed.";
	if (report.status === "published" && report.bundle_size === null && report.screenshot_size === null && report.closed_at) {
		return "Deleted when its issue was closed.";
	}
	const waiting = pendingParts(report);
	const late = report.created_at < now - LIMITS.partsGraceSeconds;
	const lines: string[] = [];
	if (report.bundle_size !== null) lines.push(`Diagnostics · ${formatBytes(report.bundle_size)}`);
	else if (waiting.includes("bundle")) lines.push(late ? "Diagnostics · never arrived" : "Diagnostics · uploading…");
	if (report.screenshot_size !== null) lines.push(`Screenshot · ${formatBytes(report.screenshot_size)}`);
	else if (waiting.includes("screenshot")) lines.push(late ? "Screenshot · never arrived" : "Screenshot · uploading…");
	return lines.length ? lines.join("\n") : "None — the words only.";
}

function repeatText(report: ReportRow, latest: RepeatRow | null): string {
	// Discord draws `<t:…:R>` as "2 hours ago" in the reader's own language.
	const lines = [`Last <t:${report.last_seen_at}:R>`];
	if (latest) {
		lines[0] += ` · ${macText({ ...latest, chip: null })}`;
		if (latest.summary) lines.push(`> ${clip(escapeMarkdown(latest.summary).replace(/\n+/g, " "), 300)}`);
	}
	return lines.join("\n");
}

function publishedText(report: ReportRow, published: Published): string {
	const issue = `[#${published.number}](${published.issueUrl}) on GitHub`;
	if (!published.postUrl) return `${issue} · the forum post isn't made yet`;
	const post = `[the post](${published.postUrl}) in ${report.kind === "idea" ? "#suggestions" : "#bug-reports"}`;
	return `${issue} · ${post}`;
}

function statusText(report: ReportRow, published: Published | null): string {
	const by = report.closed_by ? ` by <@${report.closed_by}>` : "";
	const when = report.closed_at ? ` <t:${report.closed_at}:R>` : "";
	const idea = report.kind === "idea";
	switch (report.status) {
		case "solved":
			return `Solved${by}${when}.`;
		case "published":
			if (published?.state === "duplicate") return `Closed on GitHub as a duplicate${when}.`;
			return published?.state === "open" ? "Published — Solve closes the issue." : "Published.";
		case "fixed":
			return `${idea ? "Added" : "Fixed"}${by}${when}.`;
		case "wontfix":
			return `${idea ? "Not planned" : "Won't fix"}${when}.`;
		default:
			return "Open.";
	}
}

function originText(origin: Origin, kind: ReportRow["kind"]): string {
	switch (origin) {
		case "menu":
			return kind === "idea" ? "From Help ▸ Suggest a Feature…" : "From Help ▸ Report a Bug…";
		case "command":
			return kind === "idea" ? "From /idea" : "From /bug";
		case "settings":
			return "From Settings";
		case "afterCrash":
			return "Sent after a crash";
		case "afterHang":
			return "Sent after a freeze";
		case "web":
			return "From wingcord.app";
		case "discord":
			return kind === "idea" ? "From the #suggestions form" : "From the #bug-reports form";
	}
}

/**
 * Escapes every character Discord's Markdown reads, including `:` (so a URL
 * is not made a link) and `<` (so `<@id>` is not a mention). Discord drops
 * the backslash before any punctuation, so the text reads as typed.
 */
export function escapeMarkdown(text: string): string {
	return text.replace(/[\\`*_~|<>[\]()#:@-]/g, (character) => `\\${character}`);
}

/** Cuts at `limit` characters, never inside an escape, ending with "…" (and `tail`). */
export function clip(text: string, limit: number, tail = ""): string {
	const characters = Array.from(text);
	if (characters.length <= limit) return text;
	let cut = characters.slice(0, limit - 1 - tail.length).join("");
	// A cut between a backslash and what it escapes would leave the backslash
	// escaping the ellipsis instead.
	if (/(^|[^\\])(\\\\)*\\$/.test(cut)) cut = cut.slice(0, -1);
	return `${cut}…${tail}`;
}

export function formatBytes(bytes: number): string {
	if (bytes < 1024) return `${bytes} bytes`;
	if (bytes < 1024 * 1024) return `${Math.round(bytes / 1024)} KB`;
	return `${(bytes / (1024 * 1024)).toFixed(1)} MB`;
}
