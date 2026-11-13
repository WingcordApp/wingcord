// `POST /discord`: every press and form Discord sends here (the app's
// Interactions Endpoint URL), signed with the app's Ed25519 key.
//
// Two audiences. **The inbox** — Download, Solve, Publish… and Same as…,
// and their forms — answers only someone who can manage the server, and
// only in that server; the inbox is private already, and this does not rely
// on it. **The pinned posts' form** (Report a bug, Suggest a feature)
// answers anyone in the server (forms.ts).

import { AREAS, LIMITS, PART_SPECS, nowSeconds, type Area, type Kind, type Part } from "./config";
import { concat, verifyEd25519 } from "./crypto";
import { publishedInfo } from "./discord";
import { downloadLink, objectKeys } from "./files";
import { areaOptions, reportForm, submitReportForm, type FormInteraction } from "./forms";
import { githubConfigured } from "./github";
import { json, log, problem, readLimited } from "./http";
import { clip, escapeMarkdown, formatBytes, inboxMessage } from "./inbox";
import { countSentence } from "./issue";
import {
	PARAGRAPH,
	SHORT,
	answers,
	checkbox,
	chosen,
	label,
	modal,
	stringSelect,
	text,
	textInput,
	ticked,
	type Modal,
	type Submitted,
} from "./modal";
import { closeFromInbox, publish, publishingConfigured, showCount } from "./publish";
import { deferUpdate, openModal, reply, thinking, updateMessage, type ReplyTarget } from "./responses";
import {
	claimPublishing,
	countInto,
	getIssue,
	getReport,
	issuesWithCrash,
	latestRepeat,
	mergeSightings,
	openIssues,
	reportSightings,
	sightings,
	solveReport,
	type ReportRow,
} from "./store";
import { cleanText } from "./validate";

const encoder = new TextEncoder();
const decoder = new TextDecoder();

const PING = 1;
const MESSAGE_COMPONENT = 3;
const MODAL_SUBMIT = 5;
const PONG = 1;

const ADMINISTRATOR = 1n << 3n;
const MANAGE_GUILD = 1n << 5n;

interface Interaction extends FormInteraction {
	type: number;
	token?: string;
	application_id?: string;
	guild_id?: string;
	member?: { permissions?: string; user?: { id: string } };
	data?: FormInteraction["data"] & { custom_id?: string; components?: Submitted[] };
}

export async function handleInteraction(request: Request, env: Env, ctx: ExecutionContext): Promise<Response> {
	if (!env.DISCORD_PUBLIC_KEY) return problem(503, "discord_not_configured");

	const signature = request.headers.get("X-Signature-Ed25519");
	const timestamp = request.headers.get("X-Signature-Timestamp");
	if (!signature || !timestamp) return problem(401, "unsigned");
	const body = await readLimited(request, LIMITS.interactionBytes);
	if (!body) return problem(413, "too_large");
	const signed = concat(encoder.encode(timestamp), body);
	if (!(await verifyEd25519(env.DISCORD_PUBLIC_KEY, signature, signed))) return problem(401, "bad_signature");
	// A signed press is still refused once it is old, so a copy of one cannot be replayed later.
	if (Math.abs(nowSeconds() - Number(timestamp)) > LIMITS.interactionSkewSeconds) return problem(401, "stale");

	let interaction: Interaction;
	try {
		interaction = JSON.parse(decoder.decode(body)) as Interaction;
	} catch {
		return problem(400, "invalid_json");
	}

	if (interaction.type === PING) return json({ type: PONG });
	if (interaction.type !== MESSAGE_COMPONENT && interaction.type !== MODAL_SUBMIT) {
		return reply("That isn't something this app does.");
	}
	const [action = "", argument = ""] = (interaction.data?.custom_id ?? "").split(":");

	// The pinned posts' form: anyone in the server.
	if (action === "guide" || action === "report") {
		if (interaction.guild_id !== env.DISCORD_GUILD_ID) return reply("This only works in the Wingcord server.");
		const kind: Kind | null = argument === "bug" || argument === "idea" ? argument : null;
		if (!kind) return reply("That button is from an older version of this post.");
		if (interaction.type === MESSAGE_COMPONENT) return openModal(reportForm(kind));
		return submitReportForm(interaction, env, ctx, kind);
	}

	// The inbox: the server's managers, in that server.
	if (interaction.guild_id !== env.DISCORD_GUILD_ID || !canManage(interaction.member?.permissions)) {
		return reply("Only the server's managers can do that.");
	}
	const report = argument ? await getReport(env.DB, argument) : null;
	if (!report) return reply("That report is gone — it may have expired.");
	const target: ReplyTarget = { applicationId: interaction.application_id ?? "", token: interaction.token ?? "" };

	if (interaction.type === MESSAGE_COMPONENT) {
		switch (action) {
			case "download":
				return download(env, report);
			case "solve":
				return solve(env, ctx, report, interaction.member?.user?.id ?? "", target);
			case "publish":
				return openPublish(env, ctx, report, target);
			case "same":
				return openSameAs(env, report);
			default:
				return reply("That button is from an older version of the inbox.");
		}
	}
	switch (action) {
		case "publish":
			return submitPublish(env, ctx, report, interaction, target);
		case "same":
			return submitSameAs(env, ctx, report, interaction, target);
		default:
			return reply("That form is from an older version of the inbox.");
	}
}

function canManage(permissions: string | undefined): boolean {
	if (!permissions || !/^\d+$/.test(permissions)) return false;
	const bits = BigInt(permissions);
	return (bits & ADMINISTRATOR) !== 0n || (bits & MANAGE_GUILD) !== 0n;
}

// MARK: Download and Solve

async function download(env: Env, report: ReportRow): Promise<Response> {
	const parts: Part[] = [];
	if (report.bundle_size !== null) parts.push("bundle");
	if (report.screenshot_size !== null) parts.push("screenshot");
	const kept = report.status === "open" || report.status === "published";
	if (!kept || parts.length === 0) return reply("There is nothing to download.");
	const now = nowSeconds();
	const lines = await Promise.all(
		parts.map(async (part) => {
			const size = part === "bundle" ? report.bundle_size : report.screenshot_size;
			const name = `${report.id}${PART_SPECS[part].extension}`;
			return `[${name}](${await downloadLink(env, report.id, part, now)}) · ${formatBytes(size ?? 0)}`;
		}),
	);
	log("inbox.download", { id: report.id });
	return reply(`${lines.join("\n")}\nThese links work for 10 minutes, and only you can see them.`);
}

/**
 * Solve: an unpublished report is solved here and now, its files deleted; a
 * published one has its issue closed as completed on GitHub, and the rest
 * follows from that (D27) — after the press is answered, since it waits on
 * GitHub and Discord.
 */
async function solve(env: Env, ctx: ExecutionContext, report: ReportRow, by: string, target: ReplyTarget): Promise<Response> {
	if (report.issue_number !== null && (report.status === "open" || report.status === "published")) {
		const issue = await getIssue(env.DB, report.issue_number);
		if (issue && issue.state === "open") {
			if (!githubConfigured(env)) return reply("GitHub isn't connected, so the issue can't be closed from here.");
			ctx.waitUntil(closeFromInbox(env, report, by, target));
			return deferUpdate();
		}
	}
	if (await solveReport(env.DB, report.id, nowSeconds(), by)) {
		// Its files go the moment it is solved (§2, principle 4).
		await env.BUCKET.delete(objectKeys(report.id));
		log("report.solved", { id: report.id });
	}
	const solved = await getReport(env.DB, report.id);
	if (!solved) return reply("That report is gone.");
	const latest = solved.count > 1 ? await latestRepeat(env.DB, solved.id) : null;
	return updateMessage(inboxMessage(solved, latest, nowSeconds(), await publishedInfo(env, solved)));
}

// MARK: Publish…

/** Why a report can't be published or counted any more, in a sentence. */
function movedOn(report: ReportRow): string {
	if (report.issue_number !== null) return `${report.id} is already published as #${report.issue_number}.`;
	if (report.status === "solved") return `${report.id} was solved.`;
	return `${report.id} can't be published any more.`;
}

async function openPublish(env: Env, ctx: ExecutionContext, report: ReportRow, target: ReplyTarget): Promise<Response> {
	if (report.status !== "open") return reply(movedOn(report));
	if (!publishingConfigured(env)) {
		return reply("Publishing isn't set up yet: the GitHub App's key and client ID, or a forum, are missing.");
	}
	if (report.issue_number !== null) {
		// Finish Publishing: the words are on GitHub already, so there's nothing to ask.
		if (!(await claimPublishing(env.DB, report.id, nowSeconds()))) return reply("It's being published already.");
		ctx.waitUntil(publish(env, report.id, null, target));
		return thinking();
	}
	return openModal(publishForm(report));
}

/** The Publish… form, holding the tester's words for Alex to edit (D26, D30). */
export function publishForm(report: ReportRow): Modal {
	const idea = report.kind === "idea";
	const fields: unknown[] = [
		label(
			"Title",
			"The post's name and the issue's title.",
			textInput("title", SHORT, { value: suggestedTitle(report), maxLength: LIMITS.title }),
		),
		label(
			idea ? "The idea" : "What happened",
			"As it will read in public: leave out names, servers and quotes.",
			textInput("body", PARAGRAPH, { value: report.summary, maxLength: LIMITS.formText }),
		),
		label(
			idea ? "How it would be used" : "Steps to reproduce",
			null,
			textInput("details", PARAGRAPH, { value: report.details, required: false, maxLength: LIMITS.formText }),
		),
		label("Area", "Labels the issue on GitHub.", stringSelect("area", areaOptions(report.area))),
	];
	if (report.screenshot_size !== null) {
		fields.push(
			label(
				"Publish the screenshot",
				"Look at it first (Download): a window can show other people's names and messages.",
				checkbox("screenshot", false),
			),
		);
	}
	return modal(`publish:${report.id}`, `Publish ${report.id}`, fields);
}

/** The first line of what the tester wrote, cut at a word, as a title to start from. */
export function suggestedTitle(report: Pick<ReportRow, "summary">): string {
	const line = (report.summary ?? "").split("\n").find((part) => part.trim())?.trim().replace(/\s+/g, " ") ?? "";
	if (Array.from(line).length <= LIMITS.title) return line;
	const cut = Array.from(line).slice(0, LIMITS.title - 1).join("");
	const space = cut.lastIndexOf(" ");
	return `${space > 40 ? cut.slice(0, space) : cut}…`;
}

async function submitPublish(
	env: Env,
	ctx: ExecutionContext,
	report: ReportRow,
	interaction: Interaction,
	target: ReplyTarget,
): Promise<Response> {
	if (report.status !== "open" || report.issue_number !== null) return reply(movedOn(report));
	if (!publishingConfigured(env)) return reply("Publishing isn't set up yet.");
	const answered = answers(interaction.data?.components);
	// A title is one line.
	const title = clip(cleanText(text(answered, "title"), 1000).replace(/\s+/g, " "), LIMITS.title);
	const body = cleanText(text(answered, "body"), LIMITS.formText);
	if (!title || !body) return reply("A title and the words are both needed — nothing was published.");
	const details = cleanText(text(answered, "details"), LIMITS.formText) || null;
	const picked = chosen(answered, "area");
	const area: Area = (AREAS as readonly string[]).includes(picked ?? "") ? (picked as Area) : report.area;
	const screenshot = ticked(answered, "screenshot") && report.screenshot_size !== null;

	if (!(await claimPublishing(env.DB, report.id, nowSeconds()))) return reply("It's being published already.");
	log("publish.started", { id: report.id, screenshot });
	ctx.waitUntil(publish(env, report.id, { title, body, details, area, screenshot }, target));
	return thinking();
}

// MARK: Same as…

async function openSameAs(env: Env, report: ReportRow): Promise<Response> {
	if (report.status !== "open" || report.issue_number !== null) return reply(movedOn(report));
	const issues = await openIssues(env.DB, LIMITS.sameAsChoices);
	const crashIssues = report.fingerprint ? new Set(await issuesWithCrash(env.DB, report.fingerprint)) : new Set<number>();
	// The same kind first; within it, the most recently changed.
	const ordered = [...issues].sort((a, b) => Number(b.kind === report.kind) - Number(a.kind === report.kind));
	const match = ordered.find((issue) => crashIssues.has(issue.number))?.number;

	const fields: unknown[] = [];
	if (ordered.length) {
		fields.push(
			label(
				"Issue",
				match ? "The one already holding this crash is chosen." : "Open issues the inbox published.",
				stringSelect(
					"issue",
					ordered.map((issue) => ({
						label: `#${issue.number} · ${issue.title}`,
						value: String(issue.number),
						description: `${issue.kind === "idea" ? "Idea" : "Bug"} · ${countSentence(issue).replace(/\.$/, "")}`,
						default: issue.number === match,
					})),
					{ required: false, placeholder: "Choose the issue" },
				),
			),
		);
	}
	fields.push(
		label(
			ordered.length ? "Or its number" : "Issue number",
			"Only issues the inbox published can take a count.",
			textInput("number", SHORT, { required: !ordered.length, maxLength: 120, placeholder: "12, #12 or the issue's link" }),
		),
	);
	return openModal(modal(`same:${report.id}`, `${report.id} is the same as…`, fields));
}

/** `12`, `#12`, or a link to the issue. */
export function issueNumber(typed: string): number | null {
	const value = typed.trim();
	const match = /^#?(\d{1,7})$/.exec(value) ?? /\/issues\/(\d{1,7})(?:[/?#].*)?$/.exec(value);
	return match ? Number(match[1]) : null;
}

async function submitSameAs(
	env: Env,
	ctx: ExecutionContext,
	report: ReportRow,
	interaction: Interaction,
	target: ReplyTarget,
): Promise<Response> {
	if (report.status !== "open" || report.issue_number !== null) return reply(movedOn(report));
	const answered = answers(interaction.data?.components);
	const typed = text(answered, "number").trim();
	const number = typed ? issueNumber(typed) : Number(chosen(answered, "issue") ?? Number.NaN);
	if (!number || !Number.isInteger(number)) {
		return reply(typed ? `“${escapeMarkdown(clip(typed, 40))}” isn't an issue number.` : "Choose an issue, or type its number.");
	}
	const issue = await getIssue(env.DB, number);
	if (!issue) return reply(`#${number} wasn't published from the inbox — Same as… counts only into those.`);
	if (issue.state !== "open") {
		return reply(`#${number} is closed. Reopen it on GitHub first, or publish ${report.id} on its own.`);
	}
	const seen = mergeSightings(sightings(issue), await reportSightings(env.DB, report));
	const counted = await countInto(env.DB, report, issue, seen, nowSeconds());
	if (!counted) return reply(`${report.id} moved on meanwhile — it may be published or solved already.`);
	log("same.counted", { id: report.id, issue: number, count: counted.count });
	ctx.waitUntil(showCount(env, counted, report.id, target));
	return thinking();
}
