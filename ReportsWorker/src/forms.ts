// The pinned posts' form (D32): **Report a bug** and **Suggest a feature**
// buttons on the how-to posts in #bug-reports and #suggestions open a
// Discord form for anyone in the server, and what it sends becomes a report
// in the private inbox like the app's — words only, no diagnostics, with the
// sender's Discord name for Alex to ask them more. Nothing is public until
// he publishes it.
//
// A member is limited as an install is (an hour's cap per person, the day's
// for everyone), counted under an id derived one way from their user id.

import { AREAS, AREA_TITLES, LIMITS, PART_SPECS, caps, nowSeconds, type Area, type Kind } from "./config";
import { randomKey, sha256Hex } from "./crypto";
import { postInbox, showInInbox } from "./discord";
import { objectKey } from "./files";
import { log, logError } from "./http";
import { PARAGRAPH, SHORT, answers, chosen, fileUpload, files, label, modal, stringSelect, text, textInput, type Modal, type Submitted } from "./modal";
import { reply } from "./responses";
import { completePart, countAttempt, dropPart, insertReport } from "./store";
import { BUILD, MACOS, VERSION, cleanText, type ReportInput } from "./validate";

export interface FormInteraction {
	member?: { user?: { id?: string } };
	data?: {
		components?: Submitted[];
		resolved?: { attachments?: Record<string, Attachment> };
	};
}

interface Attachment {
	url?: string;
	filename?: string;
	content_type?: string;
	size?: number;
}

const SNOWFLAKE = /^\d{17,20}$/;

/** The form a pinned post's button opens. */
export function reportForm(kind: Kind): Modal {
	if (kind === "idea") {
		return modal("report:idea", "Suggest a feature", [
			label(
				"What would you like Wingcord to do?",
				null,
				textInput("summary", PARAGRAPH, { maxLength: LIMITS.summary, placeholder: "Let me pin a chat to the top of the sidebar…" }),
			),
			label(
				"How would you use it?",
				"The situation you're in matters more than the exact solution.",
				textInput("details", PARAGRAPH, { required: false, maxLength: LIMITS.details }),
			),
			label("Where in Wingcord?", null, stringSelect("area", areaOptions(), { required: false, placeholder: "Choose the closest" })),
			label("A picture", "A sketch or a screenshot, as a PNG up to 4 MB.", fileUpload("screenshot", [".png"])),
		]);
	}
	return modal("report:bug", "Report a bug", [
		label(
			"What happened?",
			"What you did, and what Wingcord did instead.",
			textInput("summary", PARAGRAPH, { maxLength: LIMITS.summary, placeholder: "I joined a call and nobody could hear me…" }),
		),
		label(
			"How can it be made to happen again?",
			"Steps, if you know them.",
			textInput("details", PARAGRAPH, { required: false, maxLength: LIMITS.details, placeholder: "1. Join a voice channel\n2. …" }),
		),
		label("Where in Wingcord?", null, stringSelect("area", areaOptions(), { required: false, placeholder: "Choose the closest" })),
		label(
			"Wingcord and macOS versions",
			"Wingcord ▸ About Wingcord, and Apple menu ▸ About This Mac.",
			textInput("versions", SHORT, { required: false, maxLength: 80, placeholder: "Wingcord 1.0 Beta 1, macOS 27.3" }),
		),
		label("A screenshot", "A PNG up to 4 MB. If the report is published, it may be too.", fileUpload("screenshot", [".png"])),
	]);
}

export function areaOptions(selected: Area | null = null) {
	return AREAS.map((area) => ({ label: AREA_TITLES[area], value: area, default: area === selected }));
}

/** The form came back: a report for the inbox, and a thank-you only the sender sees. */
export async function submitReportForm(
	interaction: FormInteraction,
	env: Env,
	ctx: ExecutionContext,
	kind: Kind,
): Promise<Response> {
	const user = interaction.member?.user?.id ?? "";
	if (!SNOWFLAKE.test(user)) return reply("This only works in the Wingcord server.");

	const answered = answers(interaction.data?.components);
	const summary = cleanText(text(answered, "summary"), LIMITS.summary);
	if (!summary) return reply("Say what happened, then send it again.");
	let details = cleanText(text(answered, "details"), LIMITS.details) || null;
	const picked = chosen(answered, "area");
	const area: Area = (AREAS as readonly string[]).includes(picked ?? "") ? (picked as Area) : "other";
	const versions = readVersions(text(answered, "versions"));
	if (versions.asTyped) {
		// What couldn't be read as versions is kept for Alex, as written.
		details = cleanText(`${details ?? ""}\n\nVersions, as written: ${versions.asTyped}`, LIMITS.details);
	}

	const now = nowSeconds();
	const install = (await sha256Hex(`discord:${user}`)).slice(0, 32);
	const allowance = await countAttempt(env.DB, install, now, caps(env));
	if (!allowance.allowed) {
		return reply(
			allowance.reason === "too_many_today"
				? "Wingcord has had a lot of reports today — please send this one tomorrow."
				: "That's a few from you this hour — please send this one a little later.",
		);
	}

	const fileId = files(answered, "screenshot")[0];
	const attachment = fileId ? interaction.data?.resolved?.attachments?.[fileId] : undefined;
	const picture = attachment && usablePicture(attachment) ? attachment.url! : null;

	const input: ReportInput = {
		kind,
		summary,
		details,
		area,
		origin: "discord",
		appVersion: versions.app ?? "",
		appBuild: versions.build ?? "",
		macOS: versions.macos ?? "",
		model: null,
		chip: null,
		install,
		crash: null,
		attachments: picture ? ["screenshot"] : [],
	};
	// No key goes back to the sender — a Discord report is followed in its forum — so its hash is of a key nobody holds.
	const id = await insertReport(env.DB, input, await sha256Hex(randomKey()), now, user);
	log("form.report", { id, kind, screenshot: Boolean(picture) });
	ctx.waitUntil(picture ? fetchPicture(env, id, picture) : postInbox(env, id));

	const left = attachment && !picture ? "\n-# The picture was left out: only a PNG up to 4 MB can be sent." : "";
	return reply(kind === "idea" ? ideaThanks(id) + left : bugThanks(id) + left);
}

function bugThanks(id: string): string {
	return (
		`Thanks — that's **${id}**. It went to the developer only, with your Discord name so they can ask you about it. ` +
		"If it's confirmed, it gets its own post in this forum.\n" +
		"-# Crashes and call problems are fixed fastest from Wingcord itself: Help ▸ Report a Bug… sends what's needed."
	);
}

function ideaThanks(id: string): string {
	return (
		`Thanks — that's **${id}**. It went to the developer only, with your Discord name. ` +
		"Ideas worth building get their own post here, where you can vote with 👍."
	);
}

/** Discord's own copy of a PNG within the screenshot limit. */
function usablePicture(attachment: Attachment): boolean {
	if (!attachment.url || (attachment.size ?? Infinity) > PART_SPECS.screenshot.limit) return false;
	const png = attachment.content_type === "image/png" || /\.png$/i.test(attachment.filename ?? "");
	try {
		const url = new URL(attachment.url);
		return png && url.protocol === "https:" && ["cdn.discordapp.com", "media.discordapp.net"].includes(url.hostname);
	} catch {
		return false;
	}
}

/** Takes the picture from Discord into the bucket, then the inbox gets the report — without it, if it failed. */
async function fetchPicture(env: Env, id: string, url: string): Promise<void> {
	try {
		const response = await fetch(url);
		if (!response.ok) throw new Error(`Discord's file answered ${response.status}`);
		const bytes = new Uint8Array(await response.arrayBuffer());
		const spec = PART_SPECS.screenshot;
		if (bytes.byteLength > spec.limit || !spec.magic.every((byte, index) => bytes[index] === byte)) {
			throw new Error("not a PNG within the limit");
		}
		await env.BUCKET.put(objectKey(id, "screenshot"), bytes, { httpMetadata: { contentType: spec.contentType } });
		await completePart(env.DB, id, "screenshot", bytes.byteLength);
	} catch (error) {
		logError("form.picture_failed", error, { id });
		await dropPart(env.DB, id, "screenshot");
	}
	await showInInbox(env, id);
}

/** A version's number, and a pre-release after it: "1.0 Beta 1", "1.0 beta2", "1.0b1", "1.0 RC 1". */
const NUMBER = String.raw`(\d{1,4}(?:\.\d{1,4}){0,3})`;
const PRE = String.raw`(?:\s*(alpha|beta|rc)\s*(\d{1,3})|(a|b)(\d{1,3}))?`;

/** " Beta 1" from the pre-release groups that start at `at`, or nothing. */
function prereleaseName(match: RegExpExecArray, at: number): string {
	const word = (match[at] ?? match[at + 2])?.toLowerCase();
	const count = match[at + 1] ?? match[at + 3];
	if (!word || !count) return "";
	const name = word === "alpha" || word === "a" ? "Alpha" : word === "rc" ? "RC" : "Beta";
	return ` ${name} ${Number(count)}`;
}

/**
 * The versions as a sender types them: "Wingcord 1.0 Beta 1 (42), macOS
 * 27.3", "1.0 beta 1 on 27.3", "Wingcord 1.2"… The app's own "1.0 (42)"
 * first; then a version after the word Wingcord, or one under 10 (macOS's
 * are 10 and up), with no build. A pre-release's name comes along as the app
 * writes it ("Beta 1"). Whatever is left that couldn't be read is handed
 * back as typed, for Alex to see.
 */
export function readVersions(typed: string): { app: string | null; build: string | null; macos: string | null; asTyped: string | null } {
	const cleaned = cleanText(typed, 120).replace(/\s+/g, " ");
	if (!cleaned) return { app: null, build: null, macos: null, asTyped: null };

	let rest = cleaned;
	let app: string | null = null;
	let build: string | null = null;
	let number: string | null = null;
	const full = new RegExp(`${NUMBER}${PRE}\\s*\\(\\s*(\\d{1,9})\\s*\\)`, "i").exec(rest);
	const named = new RegExp(`wingcord\\s*v?${NUMBER}${PRE}(?![\\d.])`, "i").exec(rest);
	const small = new RegExp(`(?:^|[^\\d.])(\\d(?:\\.\\d{1,4}){1,3})${PRE}(?![\\d.])`, "i").exec(rest);
	if (full) {
		[number, build] = [full[1]!, full[6]!];
		app = number + prereleaseName(full, 2);
		rest = rest.replace(full[0], " ");
	} else if (named ?? small) {
		const match = (named ?? small)!;
		[number, build] = [match[1]!, ""];
		app = number + prereleaseName(match, 2);
		rest = rest.replace(match[0], " ");
	}
	if (number && !(VERSION.test(number) && (build === "" || BUILD.test(build!)))) [app, build] = [null, null];

	const system = /mac\s?os(?:\s+[a-z]+)?\s+(\d{1,3}(?:\.\d{1,3}){0,2})\b/i.exec(rest) ?? /(?:^|[^\d.])(\d{2}(?:\.\d{1,3}){0,2})(?![\d.])/.exec(rest);
	let macos: string | null = system?.[1] ?? null;
	if (macos && !MACOS.test(macos)) macos = null;
	if (system && macos) rest = rest.replace(system[0], " ");

	// Anything besides the words around versions is something they meant to say.
	const left = rest.replace(/\b(wingcord|mac\s?os|on|and|version|v)\b/gi, "").replace(/[\s,.;:/()–—-]+/g, "");
	return { app, build, macos, asTyped: left ? cleaned : null };
}
