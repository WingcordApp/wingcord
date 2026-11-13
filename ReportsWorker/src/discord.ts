// The bot's side of Discord: its REST calls, and posting or updating a
// report's inbox message. **The bot never connects to the gateway** — the
// Worker speaks for it over REST with its token (D25), so there is nothing
// else to run, and it shows as offline.

import { nowSeconds } from "./config";
import { issueUrl } from "./github";
import { log, logError } from "./http";
import { inboxMessage, type Embed, type Published } from "./inbox";
import { claimInbox, getIssue, getReport, isPosted, latestRepeat, releaseInbox, setInbox, type ReportRow } from "./store";

const API = "https://discord.com/api/v10";

/** A message as the bot sends it. Mentions are always off. */
export interface MessagePayload {
	content?: string;
	embeds?: Embed[];
	components?: unknown[];
	allowed_mentions: { parse: [] };
	flags?: number;
	/** The files sent with it, by their index in the upload. */
	attachments?: { id: number; filename: string; description?: string }[];
}

/** A forum post as Discord takes it: the title, the first message, the tags. */
export interface ForumPost {
	name: string;
	message: MessagePayload;
	applied_tags?: string[];
}

/** A file sent with a message. */
export interface Upload {
	name: string;
	type: string;
	bytes: Uint8Array;
}

export interface ForumTag {
	id: string;
	name: string;
}

/** A forum post's flag that keeps it at the top of its forum. */
export const PINNED = 1 << 1;
/** A message flag: no link previews. */
export const SUPPRESS_EMBEDS = 1 << 2;
/** A message flag: only the presser sees it. */
export const EPHEMERAL = 1 << 6;

export class DiscordError extends Error {
	constructor(
		readonly status: number,
		readonly code: number | null,
	) {
		super(`Discord answered ${status}${code === null ? "" : ` (code ${code})`}`);
	}
}

/** A forum post's address. */
export function postUrl(env: Env, postId: string): string {
	return `https://discord.com/channels/${env.DISCORD_GUILD_ID}/${postId}`;
}

export class DiscordBot {
	constructor(private readonly token: string) {}

	async createMessage(channelId: string, body: MessagePayload): Promise<{ id: string }> {
		const response = await this.call("POST", `/channels/${channelId}/messages`, body);
		return response.json<{ id: string }>();
	}

	async editMessage(channelId: string, messageId: string, body: MessagePayload): Promise<void> {
		const response = await this.call("PATCH", `/channels/${channelId}/messages/${messageId}`, body);
		await response.body?.cancel();
	}

	/** A new post in a forum: its title, first message and tags, and a file. Returns the post's id. */
	async createForumPost(forumId: string, post: ForumPost, file?: Upload): Promise<{ id: string }> {
		const response = await this.call("POST", `/channels/${forumId}/threads`, file ? multipart(post, file) : post);
		return response.json<{ id: string }>();
	}

	/** A forum's tags. */
	async forumTags(forumId: string): Promise<ForumTag[]> {
		const response = await this.call("GET", `/channels/${forumId}`, null);
		const channel = await response.json<{ available_tags?: ForumTag[] }>();
		return channel.available_tags ?? [];
	}

	/** Changes a channel or a post: its name, tags, whether it is pinned, locked or archived. */
	async editChannel(channelId: string, changes: Record<string, unknown>): Promise<void> {
		const response = await this.call("PATCH", `/channels/${channelId}`, changes);
		await response.body?.cancel();
	}

	/** Rewrites the answer to a press that was deferred — the interaction's token stands in for the bot's. */
	async editReply(applicationId: string, interactionToken: string, body: MessagePayload): Promise<void> {
		const response = await this.call(
			"PATCH",
			`/webhooks/${applicationId}/${interactionToken}/messages/@original`,
			body,
			false,
		);
		await response.body?.cancel();
	}

	/** A further answer to a press, as the bot. */
	async followUp(applicationId: string, interactionToken: string, body: MessagePayload): Promise<void> {
		const response = await this.call("POST", `/webhooks/${applicationId}/${interactionToken}`, body, false);
		await response.body?.cancel();
	}

	private async call(method: string, path: string, body: unknown, authorized = true, retried = false): Promise<Response> {
		const headers: Record<string, string> = {
			// Discord asks bots to say who they are in this form.
			"User-Agent": "DiscordBot (https://wingcord.app, 1)",
		};
		if (authorized) headers.Authorization = `Bot ${this.token}`;
		let payload: BodyInit | undefined;
		if (body instanceof FormData) {
			payload = body; // fetch sets the multipart boundary
		} else if (body !== null) {
			headers["Content-Type"] = "application/json";
			payload = JSON.stringify(body);
		}
		const response = await fetch(API + path, { method, headers, body: payload });
		if (response.status === 429 && !retried) {
			const { retry_after } = await response.json<{ retry_after?: number }>().catch(() => ({ retry_after: 1 }));
			const wait = Math.max(0, Number(retry_after ?? 1));
			// Waiting is free (it is not CPU time); a long wait is left to the next cron.
			if (wait <= 5) {
				await new Promise((resolve) => setTimeout(resolve, wait * 1000));
				return this.call(method, path, body, authorized, true);
			}
		}
		if (!response.ok) {
			// Only Discord's error code is kept: its message can quote what was sent.
			const code = await response
				.json<{ code?: number }>()
				.then((error) => error.code ?? null)
				.catch(() => null);
			throw new DiscordError(response.status, code);
		}
		return response;
	}
}

/** A post with a file: the JSON as `payload_json`, the file as `files[0]` (Discord's "Uploading Files"). */
function multipart(post: ForumPost, file: Upload): FormData {
	const form = new FormData();
	const message: MessagePayload = { ...post.message, attachments: [{ id: 0, filename: file.name }] };
	form.set("payload_json", JSON.stringify({ ...post, message }));
	form.set("files[0]", new File([file.bytes], file.name, { type: file.type }));
	return form;
}

export function inboxConfigured(env: Env): boolean {
	return Boolean(env.DISCORD_BOT_TOKEN && env.DISCORD_INBOX_CHANNEL_ID);
}

/** Where a published report can be followed, for its inbox message and the tester's status. */
export async function publishedInfo(env: Env, report: Pick<ReportRow, "issue_number">): Promise<Published | null> {
	if (report.issue_number === null) return null;
	const issue = await getIssue(env.DB, report.issue_number);
	return {
		number: report.issue_number,
		state: issue?.state ?? "open",
		issueUrl: issueUrl(env, report.issue_number),
		postUrl: issue?.forum_post_id ? postUrl(env, issue.forum_post_id) : null,
	};
}

/**
 * Posts a report's inbox message — once: the claim in D1 stops the upload
 * that completes a report and the cron from both posting. On failure the
 * claim is released and the cron tries again within 15 minutes.
 */
export async function postInbox(env: Env, id: string): Promise<void> {
	if (!inboxConfigured(env)) return;
	const now = nowSeconds();
	if (!(await claimInbox(env.DB, id, now))) return;
	try {
		const report = await getReport(env.DB, id);
		if (!report) return;
		const latest = report.count > 1 ? await latestRepeat(env.DB, id) : null;
		const bot = new DiscordBot(env.DISCORD_BOT_TOKEN);
		const message = await bot.createMessage(
			env.DISCORD_INBOX_CHANNEL_ID,
			inboxMessage(report, latest, now, await publishedInfo(env, report)),
		);
		await setInbox(env.DB, id, message.id);
		log("inbox.posted", { id });
	} catch (error) {
		await releaseInbox(env.DB, id);
		logError("inbox.post_failed", error, { id });
	}
}

/** Redraws a report's inbox message after it changed (a part arrived, a repeat, publishing, a close). */
export async function refreshInbox(env: Env, report: ReportRow): Promise<void> {
	if (!inboxConfigured(env) || !isPosted(report)) return;
	try {
		const latest = report.count > 1 ? await latestRepeat(env.DB, report.id) : null;
		const bot = new DiscordBot(env.DISCORD_BOT_TOKEN);
		await bot.editMessage(
			env.DISCORD_INBOX_CHANNEL_ID,
			report.inbox_message_id,
			inboxMessage(report, latest, nowSeconds(), await publishedInfo(env, report)),
		);
	} catch (error) {
		logError("inbox.refresh_failed", error, { id: report.id });
	}
}

/** Posts the report if the inbox has not had it, or redraws it if it has. */
export async function showInInbox(env: Env, id: string): Promise<void> {
	const report = await getReport(env.DB, id);
	if (!report) return;
	if (isPosted(report)) await refreshInbox(env, report);
	else await postInbox(env, id);
}
