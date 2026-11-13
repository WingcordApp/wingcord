// What a published report says in the server's forum, and how its post
// follows the issue on GitHub (D26, D27).
//
// **The words are plain text here**, escaped as the inbox escapes them, so
// nothing in them links, mentions or formats; every message also has
// mentions off. The post links to its issue with a button.

import { FORUM_TAGS, LIMITS, type IssueState } from "./config";
import { DiscordBot, SUPPRESS_EMBEDS, type ForumTag, type MessagePayload, type Upload } from "./discord";
import { clip, escapeMarkdown } from "./inbox";
import { countSentence, detailsHeading } from "./issue";
import { sightings, type IssueRow } from "./store";

const CONTENT_LIMIT = 2000;

export function forumFor(env: Env, issue: Pick<IssueRow, "kind">): string {
	return issue.kind === "idea" ? env.DISCORD_IDEAS_FORUM_ID : env.DISCORD_BUGS_FORUM_ID;
}

/** The post's first message: the words, the steps, where it was seen, and a button to the issue. */
export function postMessage(issue: IssueRow, issueUrl: string): MessagePayload {
	const footer = `-# ${seenSummary(issue)}`;
	const details = issue.details
		? `\n\n**${detailsHeading(issue)}**\n${clip(escapeMarkdown(issue.details), 600)}`
		: "";
	// Discord counts the 2,000 in UTF-16 units; `clip` counts characters, so it is checked again.
	let room = CONTENT_LIMIT - footer.length - details.length - 2;
	let content = "";
	for (let attempt = 0; attempt < 4; attempt++) {
		content = `${clip(escapeMarkdown(issue.body), room)}${details}\n\n${footer}`;
		if (content.length <= CONTENT_LIMIT) break;
		room -= content.length - CONTENT_LIMIT + 8;
	}
	return {
		content,
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
	const file: Upload | undefined = screenshot
		? { name: `${issue.first_report}.png`, type: "image/png", bytes: screenshot }
		: undefined;
	const post = await bot.createForumPost(
		forum,
		{ name: clip(issue.title, LIMITS.title), message: postMessage(issue, issueUrl), applied_tags: postTags(issue, ids) },
		file,
	);
	return post.id;
}

/** Rewrites the first message after Same as… changed the count or the Macs. */
export async function redrawPost(bot: DiscordBot, issue: IssueRow, issueUrl: string): Promise<void> {
	if (!issue.forum_post_id) return;
	// A forum post's first message has the post's own id.
	await bot.editMessage(issue.forum_post_id, issue.forum_post_id, postMessage(issue, issueUrl));
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
