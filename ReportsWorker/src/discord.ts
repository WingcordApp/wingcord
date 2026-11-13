// The bot's side of Discord: its REST calls, and posting or updating a
// report's inbox message. **The bot never connects to the gateway** — the
// Worker speaks for it over REST with its token (D25), so there is nothing
// else to run, and it shows as offline.

import { nowSeconds } from "./config";
import { log, logError } from "./http";
import { inboxMessage, type MessageBody } from "./inbox";
import { claimInbox, getReport, isPosted, latestRepeat, releaseInbox, setInbox, type ReportRow } from "./store";

const API = "https://discord.com/api/v10";

/** A forum post as Discord takes it: the title, and the first message. */
export interface ForumPost {
	name: string;
	message: { content: string; allowed_mentions: { parse: [] } };
	applied_tags?: string[];
}

/** A forum post's flag that keeps it at the top of its forum. */
export const PINNED = 1 << 1;

export class DiscordError extends Error {
	constructor(
		readonly status: number,
		readonly code: number | null,
	) {
		super(`Discord answered ${status}${code === null ? "" : ` (code ${code})`}`);
	}
}

export class DiscordBot {
	constructor(private readonly token: string) {}

	async createMessage(channelId: string, body: MessageBody): Promise<{ id: string }> {
		const response = await this.call("POST", `/channels/${channelId}/messages`, body);
		return response.json<{ id: string }>();
	}

	async editMessage(channelId: string, messageId: string, body: MessageBody): Promise<void> {
		const response = await this.call("PATCH", `/channels/${channelId}/messages/${messageId}`, body);
		await response.body?.cancel();
	}

	/** A new post in a forum channel: its title and first message. Returns the post's id. */
	async createForumPost(forumId: string, post: ForumPost): Promise<{ id: string }> {
		const response = await this.call("POST", `/channels/${forumId}/threads`, post);
		return response.json<{ id: string }>();
	}

	/** Changes a channel or a post: its tags, whether it is pinned, locked or archived. */
	async editChannel(channelId: string, changes: Record<string, unknown>): Promise<void> {
		const response = await this.call("PATCH", `/channels/${channelId}`, changes);
		await response.body?.cancel();
	}

	private async call(method: string, path: string, body: unknown, retried = false): Promise<Response> {
		const response = await fetch(API + path, {
			method,
			headers: {
				Authorization: `Bot ${this.token}`,
				"Content-Type": "application/json",
				// Discord asks bots to say who they are in this form.
				"User-Agent": "DiscordBot (https://wingcord.app, 1)",
			},
			body: JSON.stringify(body),
		});
		if (response.status === 429 && !retried) {
			const { retry_after } = await response.json<{ retry_after?: number }>().catch(() => ({ retry_after: 1 }));
			const wait = Math.max(0, Number(retry_after ?? 1));
			// Waiting is free (it is not CPU time); a long wait is left to the next cron.
			if (wait <= 5) {
				await new Promise((resolve) => setTimeout(resolve, wait * 1000));
				return this.call(method, path, body, true);
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

export function inboxConfigured(env: Env): boolean {
	return Boolean(env.DISCORD_BOT_TOKEN && env.DISCORD_INBOX_CHANNEL_ID);
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
		const message = await bot.createMessage(env.DISCORD_INBOX_CHANNEL_ID, inboxMessage(report, latest, now));
		await setInbox(env.DB, id, message.id);
		log("inbox.posted", { id });
	} catch (error) {
		await releaseInbox(env.DB, id);
		logError("inbox.post_failed", error, { id });
	}
}

/** Redraws a report's inbox message after it changed (a part arrived, a repeat, a close). */
export async function refreshInbox(env: Env, report: ReportRow): Promise<void> {
	if (!inboxConfigured(env) || !isPosted(report)) return;
	try {
		const latest = report.count > 1 ? await latestRepeat(env.DB, report.id) : null;
		const bot = new DiscordBot(env.DISCORD_BOT_TOKEN);
		await bot.editMessage(
			env.DISCORD_INBOX_CHANNEL_ID,
			report.inbox_message_id,
			inboxMessage(report, latest, nowSeconds()),
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
