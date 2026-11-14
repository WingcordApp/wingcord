// What a published report says in the server's forum, and how its post
// follows the issue on GitHub (D26, D27).
//
// **The post opens with a card**, drawn as the pinned guides are
// (scripts/post-guides.py): what it is, the words, the steps, where it was
// seen, the screenshot when it was published — and under it a button to the
// issue. The words are escaped as the inbox escapes them, so nothing in them
// links, mentions or formats; every message also has mentions off.

import { FORUM_TAGS, LIMITS, type IssueState } from "./config";
import { DiscordBot, SUPPRESS_EMBEDS, type ForumTag, type MessagePayload, type Upload } from "./discord";
import { clip, escapeMarkdown, type Embed } from "./inbox";
import { countSentence, detailsHeading } from "./issue";
import { sightings, type IssueRow } from "./store";

/** The card's text, at most — Discord counts it in UTF-16 units. */
const DESCRIPTION_LIMIT = 4096;
/** The steps' share of it; the words get the rest. */
const DETAILS_LIMIT = 1500;
/** The app icon's orange, as on the pinned guides. */
const CARD_COLOR = 0xff7b1c;

export function forumFor(env: Env, issue: Pick<IssueRow, "kind">): string {
	return issue.kind === "idea" ? env.DISCORD_IDEAS_FORUM_ID : env.DISCORD_BUGS_FORUM_ID;
}

/** What the card says it is, as the guides' titles do: "🐛 Bug", "💥 Crash", "💡 Idea". */
export function cardTitle(issue: Pick<IssueRow, "kind" | "crash">): string {
	if (issue.kind === "idea") return "💡 Idea";
	return issue.crash ? "💥 Crash" : "🐛 Bug";
}

/** The screenshot's file name in the post, which the card shows it by. */
export function screenshotName(issue: Pick<IssueRow, "first_report">): string {
	return `${issue.first_report}.png`;
}

/**
 * The post's first message: the card, and the button to the issue under it.
 * `withScreenshot` puts the file sent with the message in the card. The
 * content is sent empty, so a redraw also clears a post from before the card.
 */
export function postMessage(issue: IssueRow, issueUrl: string, withScreenshot = false): MessagePayload {
	const footer = `-# ${seenSummary(issue)}`;
	const details = issue.details
		? `\n\n**${detailsHeading(issue)}**\n${clip(escapeMarkdown(issue.details), DETAILS_LIMIT)}`
		: "";
	// `clip` counts characters and Discord counts UTF-16 units, so the length is checked again.
	let room = DESCRIPTION_LIMIT - footer.length - details.length - 2;
	let description = "";
	for (let attempt = 0; attempt < 4; attempt++) {
		description = `${clip(escapeMarkdown(issue.body), room)}${details}\n\n${footer}`;
		if (description.length <= DESCRIPTION_LIMIT) break;
		room -= description.length - DESCRIPTION_LIMIT + 8;
	}
	const card: Embed = { title: cardTitle(issue), description, color: CARD_COLOR, fields: [] };
	if (withScreenshot) card.image = { url: `attachment://${screenshotName(issue)}` };
	return {
		content: "",
		embeds: [card],
		components: [{ type: 1, components: [{ type: 2, style: 5, label: `#${issue.number} on GitHub`, url: issueUrl }] }],
		allowed_mentions: { parse: [] },
	};
}

/** "Seen in Wingcord 1.0 (42) on macOS 27.3 · reported 3 times" — one line under the words. */
export function seenSummary(issue: Pick<IssueRow, "kind" | "count" | "seen">): string {
	const count = countSentence(issue).replace(/\.$/, "");
	const seen = sightings(issue);
	const apps = [...new Set(seen.map((sighting) => sighting.app).filter(Boolean))];
	const systems = [...new Set(seen.map((sighting) => sighting.macos).filter(Boolean))];
	if (issue.kind === "idea" || (apps.length === 0 && systems.length === 0)) return count;
	let line = "Seen";
	if (apps.length) line += ` in Wingcord ${listed(apps)}`;
	if (systems.length) line += ` on macOS ${listed(systems)}`;
	return `${line} · ${count.charAt(0).toLowerCase()}${count.slice(1)}`;
}

function listed(values: string[]): string {
	const shown = values.slice(-4);
	const more = values.length - shown.length;
	return shown.join(", ") + (more > 0 ? ` and ${more} more` : "");
}

// MARK: Tags

/** Matches a tag's name however its case or apostrophe is typed. */
function tagKey(name: string): string {
	return name.trim().toLowerCase().replace(/[’‘`´]/g, "'");
}

export function tagIds(tags: ForumTag[]): Map<string, string> {
	return new Map(tags.map((tag) => [tagKey(tag.name), tag.id]));
}

/** The tags a post wears: what it is, then where it stands (D27). Tags the forum lacks are left out. */
export function postTags(issue: Pick<IssueRow, "kind" | "crash" | "state" | "planned">, ids: Map<string, string>): string[] {
	const names: string[] = [];
	if (issue.kind === "idea") {
		names.push(FORUM_TAGS.idea);
		if (issue.state === "fixed") names.push(FORUM_TAGS.added);
		else if (issue.state === "wontfix") names.push(FORUM_TAGS.notPlanned);
		else if (issue.state === "open" && issue.planned) names.push(FORUM_TAGS.planned);
	} else {
		names.push(FORUM_TAGS.bug);
		if (issue.crash) names.push(FORUM_TAGS.crash);
		if (issue.state === "fixed") names.push(FORUM_TAGS.fixed);
		else if (issue.state === "wontfix") names.push(FORUM_TAGS.wontfix);
	}
	return names.map((name) => ids.get(tagKey(name))).filter((id): id is string => Boolean(id));
}

// MARK: The post

/** Makes the post for a published issue, with the screenshot when it was ticked. Returns its id. */
export async function createPost(
	env: Env,
	bot: DiscordBot,
	issue: IssueRow,
	issueUrl: string,
	screenshot: Uint8Array | null,
): Promise<string> {
	const forum = forumFor(env, issue);
	const ids = tagIds(await bot.forumTags(forum));
	const file = screenshot ? screenshotUpload(issue, screenshot) : undefined;
	const post = await bot.createForumPost(
		forum,
		{
			name: clip(issue.title, LIMITS.title),
			message: postMessage(issue, issueUrl, Boolean(file)),
			applied_tags: postTags(issue, ids),
		},
		file,
	);
	return post.id;
}

/**
 * Rewrites the first message after Same as… changed the count or the Macs.
 * The screenshot is sent again with it — the card can only be sure of a file
 * that comes with the edit — and without one, no file is kept, so a post's
 * picture never hangs loose outside its card.
 */
export async function redrawPost(bot: DiscordBot, issue: IssueRow, issueUrl: string, screenshot: Uint8Array | null): Promise<void> {
	if (!issue.forum_post_id) return;
	const file = screenshot ? screenshotUpload(issue, screenshot) : undefined;
	const message = file ? postMessage(issue, issueUrl, true) : { ...postMessage(issue, issueUrl), attachments: [] };
	// A forum post's first message has the post's own id.
	await bot.editMessage(issue.forum_post_id, issue.forum_post_id, message, file);
}

function screenshotUpload(issue: Pick<IssueRow, "first_report">, bytes: Uint8Array): Upload {
	return { name: screenshotName(issue), type: "image/png", bytes };
}

/** What the post says when GitHub closes or reopens its issue. */
export function stateLine(issue: Pick<IssueRow, "kind" | "number">, state: IssueState, issueUrl: string): string {
	const link = `[#${issue.number}](${issueUrl})`;
	const idea = issue.kind === "idea";
	switch (state) {
		case "fixed":
			return idea
				? `✨ **Added** — closed on GitHub as ${link}. Thanks for suggesting it.`
				: `✅ **Fixed** — closed on GitHub as ${link}. Thanks to everyone who reported it.`;
		case "wontfix":
			return idea ? `**Not planned** — closed on GitHub as ${link}.` : `**Won't fix** — closed on GitHub as ${link}.`;
		case "duplicate":
			return `Closed on GitHub as a duplicate — ${link} links to the one to follow.`;
		case "open":
			return `↩️ **Reopened** on GitHub as ${link}.`;
	}
}

/**
 * Brings the post in line with its issue's new state: a closed one gets its
 * verdict tag, a line saying so, and is locked and archived; a reopened one
 * is opened again first, then told. Archived posts are opened before
 * anything is said in them.
 */
export async function showState(env: Env, bot: DiscordBot, issue: IssueRow, issueUrl: string): Promise<void> {
	if (!issue.forum_post_id) return;
	const ids = tagIds(await bot.forumTags(forumFor(env, issue)));
	const tags = postTags(issue, ids);
	const line: MessagePayload = {
		content: stateLine(issue, issue.state, issueUrl),
		allowed_mentions: { parse: [] },
		flags: SUPPRESS_EMBEDS,
	};
	if (issue.state === "open") {
		await bot.editChannel(issue.forum_post_id, { archived: false, locked: false, applied_tags: tags });
		await bot.createMessage(issue.forum_post_id, line);
	} else {
		await bot.editChannel(issue.forum_post_id, { archived: false, applied_tags: tags });
		await bot.createMessage(issue.forum_post_id, line);
		await bot.editChannel(issue.forum_post_id, { locked: true, archived: true });
	}
}

/** The `planned` label came or went: only the tags change. */
export async function showPlanned(env: Env, bot: DiscordBot, issue: IssueRow): Promise<void> {
	if (!issue.forum_post_id || issue.state !== "open") return;
	const ids = tagIds(await bot.forumTags(forumFor(env, issue)));
	await bot.editChannel(issue.forum_post_id, { applied_tags: postTags(issue, ids) });
}

/** The issue was renamed: so is the post. A closed post is opened for it, then closed again. */
export async function renamePost(bot: DiscordBot, issue: IssueRow): Promise<void> {
	if (!issue.forum_post_id) return;
	const name = clip(issue.title, LIMITS.title);
	if (issue.state === "open") {
		await bot.editChannel(issue.forum_post_id, { name });
	} else {
		await bot.editChannel(issue.forum_post_id, { archived: false, name });
		await bot.editChannel(issue.forum_post_id, { archived: true });
	}
}
