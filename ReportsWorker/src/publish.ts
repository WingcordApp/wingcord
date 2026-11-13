// Publishing (D26), Same as…, and an issue's life on GitHub shown in the
// forum and the inbox (D27).
//
// **Every step is written down before the next one starts**, so a press
// that fails part-way is finished by the next press without repeating
// anything: the issue number is kept the moment GitHub hands it over, the
// post id the moment Discord does. GitHub's events and the inbox's Solve
// both move an issue through `applyIssueState`, which acts once per change
// however many times it hears of it.

import { LIMITS, nowSeconds, type Area, type IssueState, type Status } from "./config";
import { DiscordBot, DiscordError, EPHEMERAL, inboxConfigured, postUrl, refreshInbox } from "./discord";
import { objectKey, objectKeys, publishedKey } from "./files";
import { createPost, redrawPost, renamePost, showPlanned, showState } from "./forum";
import { GitHub, GitHubError, issueUrl } from "./github";
import { log, logError } from "./http";
import { issueBody, issueLabels, issueType, linksSection, replaceSection, seenSection } from "./issue";
import { outcome, type ReplyTarget } from "./responses";
import {
	claimIssueState,
	claimPostState,
	closeReports,
	getIssue,
	getReport,
	markPublished,
	mergeSightings,
	recordIssue,
	releasePublishing,
	renameIssue,
	reopenReports,
	reportSightings,
	reportsForIssue,
	setForumPost,
	setLinked,
	setPlanned,
	setPostState,
	type IssueRow,
	type ReportRow,
} from "./store";

/** What Alex left in the Publish… form. */
export interface PublishForm {
	title: string;
	body: string;
	details: string | null;
	area: Area;
	/** Ticked: the tester's screenshot goes public with it. */
	screenshot: boolean;
}

/** A refusal worth saying in Alex's words. */
class PublishError extends Error {}

/** Everything publishing needs: GitHub's App and the bot with both forums. */
export function publishingConfigured(env: Env): boolean {
	return Boolean(
		env.GITHUB_APP_CLIENT_ID &&
			env.GITHUB_APP_PRIVATE_KEY &&
			env.GITHUB_REPOSITORY &&
			inboxConfigured(env) &&
			env.DISCORD_BUGS_FORUM_ID &&
			env.DISCORD_IDEAS_FORUM_ID,
	);
}

/**
 * Publish… (or Finish Publishing, with no form): the issue, the post, the
 * issue's link to the post, then the report marked published. Runs after
 * the press was answered; the outcome rewrites Alex's "thinking…" reply.
 * The report was claimed by the caller and is released here.
 */
export async function publish(env: Env, reportId: string, form: PublishForm | null, target: ReplyTarget): Promise<void> {
	const bot = new DiscordBot(env.DISCORD_BOT_TOKEN);
	let message: string;
	try {
		const issue = await publishSteps(env, bot, reportId, form);
		const forum = issue.kind === "idea" ? "#suggestions" : "#bug-reports";
		message = `Published as [#${issue.number}](${issueUrl(env, issue.number)}) on GitHub and [a post](${postUrl(env, issue.forum_post_id!)}) in ${forum}.`;
		log("publish.done", { id: reportId, issue: issue.number });
	} catch (error) {
		logError("publish.failed", error, { id: reportId });
		const report = await getReport(env.DB, reportId);
		const again = report?.issue_number !== null && report?.issue_number !== undefined;
		message = `${describe(error)}${again ? " Press **Finish Publishing** to try the rest — what was made is kept." : ""}`;
	} finally {
		await releasePublishing(env.DB, reportId);
	}
	await tell(bot, env, target, message);
	const report = await getReport(env.DB, reportId);
	if (report) await refreshInbox(env, report);
}

async function publishSteps(env: Env, bot: DiscordBot, reportId: string, form: PublishForm | null): Promise<IssueRow> {
	const github = new GitHub(env);
	const report = await getReport(env.DB, reportId);
	if (!report) throw new PublishError("That report is gone — it may have expired.");

	let issue = report.issue_number !== null ? await getIssue(env.DB, report.issue_number) : null;
	let screenshot: Uint8Array | null = null;
	let fresh = false;

	if (!issue) {
		if (!form) throw new PublishError("There's nothing to finish: press Publish… to start again.");
		if (form.screenshot && report.screenshot_size !== null) screenshot = await publishScreenshot(env, report.id);
		const now = nowSeconds();
		const draft: IssueRow = {
			number: 0,
			kind: report.kind,
			crash: report.crash_kind !== null || form.area === "crash" ? 1 : 0,
			area: form.area,
			title: form.title,
			body: form.body,
			details: form.details,
			first_report: report.id,
			origin: report.origin,
			screenshot: screenshot ? 1 : 0,
			forum_post_id: null,
			linked: 0,
			state: "open",
			post_state: "open",
			planned: 0,
			count: report.count,
			seen: JSON.stringify(mergeSightings([], await reportSightings(env.DB, report))),
			created_at: now,
			updated_at: now,
		};
		const number = await github.createIssue({
			title: draft.title,
			body: issueBody(env, draft, null),
			labels: issueLabels(draft),
			type: issueType(draft),
		});
		issue = { ...draft, number };
		await recordIssue(env.DB, issue, report.id);
		fresh = true;
		log("publish.issue", { id: report.id, issue: number });
	} else if (issue.state !== "open") {
		throw new PublishError(`#${issue.number} was closed on GitHub before publishing finished.`);
	}

	if (!issue.forum_post_id) {
		if (issue.screenshot && !screenshot) screenshot = await readObject(env, publishedKey(issue.first_report));
		const postId = await createPost(env, bot, issue, issueUrl(env, issue.number), screenshot);
		await setForumPost(env.DB, issue.number, postId, nowSeconds());
		issue = { ...issue, forum_post_id: postId };
		log("publish.post", { id: report.id, issue: issue.number });
	}

	if (!issue.linked) {
		const post = postUrl(env, issue.forum_post_id!);
		if (fresh) {
			// Made seconds ago: nobody has edited it yet.
			await github.updateIssue(issue.number, { body: issueBody(env, issue, post) });
		} else {
			const current = await github.getIssue(issue.number);
			const body = replaceSection(current.body ?? "", linksSection(issue, post), "links");
			if (body !== null) await github.updateIssue(issue.number, { body });
		}
		await setLinked(env.DB, issue.number);
		issue = { ...issue, linked: 1 };
	}

	await markPublished(env.DB, report.id);
	return issue;
}

/** Copies the tester's screenshot to its public path, outside the 90-day rule (D26). */
async function publishScreenshot(env: Env, reportId: string): Promise<Uint8Array | null> {
	const bytes = await readObject(env, objectKey(reportId, "screenshot"));
	if (!bytes) return null;
	await env.BUCKET.put(publishedKey(reportId), bytes, { httpMetadata: { contentType: "image/png" } });
	return bytes;
}

async function readObject(env: Env, key: string): Promise<Uint8Array | null> {
	const object = await env.BUCKET.get(key);
	return object ? new Uint8Array(await object.arrayBuffer()) : null;
}

// MARK: Same as…

/**
 * After Same as… counted a report into `issue` (in D1, by the caller): the
 * count and the Macs on GitHub and in the post. None of the tester's words
 * go anywhere.
 */
export async function showCount(env: Env, issue: IssueRow, reportId: string, target: ReplyTarget): Promise<void> {
	const bot = new DiscordBot(env.DISCORD_BOT_TOKEN);
	const problems: string[] = [];
	if (githubOn(env)) {
		try {
			const github = new GitHub(env);
			const current = await github.getIssue(issue.number);
			const body = replaceSection(current.body ?? "", seenSection(issue), "seen");
			if (body !== null && body !== current.body) await github.updateIssue(issue.number, { body });
		} catch (error) {
			logError("same.github_failed", error, { id: reportId, issue: issue.number });
			problems.push(describe(error));
		}
	}
	try {
		await redrawPost(bot, issue, issueUrl(env, issue.number));
	} catch (error) {
		logError("same.post_failed", error, { id: reportId, issue: issue.number });
		problems.push(describe(error));
	}
	const counted = `Counted into [#${issue.number}](${issueUrl(env, issue.number)}) — ${issue.count === 1 ? "once" : `${issue.count} times`} now.`;
	await tell(bot, env, target, problems.length ? `${counted} The public count didn't all update: ${problems.join(" ")}` : counted);
	const report = await getReport(env.DB, reportId);
	if (report) await refreshInbox(env, report);
}

// MARK: Closing, reopening, planned, renamed

/** Solve on a published report: its issue is closed as completed on GitHub, and everything follows. */
export async function closeFromInbox(env: Env, report: ReportRow, by: string, target: ReplyTarget): Promise<void> {
	const number = report.issue_number!;
	try {
		await new GitHub(env).updateIssue(number, { state: "closed", state_reason: "completed" });
		await applyIssueState(env, number, "fixed", by || null);
		log("inbox.closed_issue", { id: report.id, issue: number });
	} catch (error) {
		logError("inbox.close_failed", error, { id: report.id, issue: number });
		const bot = new DiscordBot(env.DISCORD_BOT_TOKEN);
		await bot
			.followUp(env.DISCORD_APPLICATION_ID, target.token, {
				content: `#${number} wasn't closed: ${describe(error)}`,
				flags: EPHEMERAL,
				allowed_mentions: { parse: [] },
			})
			.catch((followUpError) => logError("inbox.follow_up_failed", followUpError, { id: report.id }));
	}
	await redrawInbox(env, number);
}

/**
 * Moves an issue to `state` and shows it: the reports counted into it are
 * closed with it (their private files deleted) or opened again, and the post
 * is tagged, told, and locked and archived — or opened. Each part happens
 * once: a change already made is skipped, and a post change that failed is
 * tried again by the next delivery of the event.
 */
export async function applyIssueState(env: Env, number: number, state: IssueState, by: string | null = null): Promise<void> {
	const now = nowSeconds();
	const changed = await claimIssueState(env.DB, number, state, now);
	if (changed) {
		if (state === "open") {
			await reopenReports(env.DB, number);
		} else {
			const ids = await closeReports(env.DB, number, reportStatus(state), now, by);
			if (ids.length) await env.BUCKET.delete(ids.flatMap(objectKeys));
		}
		log("issue.state", { issue: number, state, was: changed.previous });
	}
	const issue = changed?.issue ?? (await getIssue(env.DB, number));
	if (!issue || issue.state !== state || !issue.forum_post_id || !inboxConfigured(env)) return;
	const shown = await claimPostState(env.DB, number, state);
	if (shown === null) return;
	try {
		await showState(env, new DiscordBot(env.DISCORD_BOT_TOKEN), issue, issueUrl(env, number));
	} catch (error) {
		await setPostState(env.DB, number, shown);
		throw error;
	}
}

/** A closed issue's reports: fixed, won't fix — or still "published" for a duplicate, whose issue links on. */
function reportStatus(state: Exclude<IssueState, "open">): Status {
	return state === "fixed" ? "fixed" : state === "wontfix" ? "wontfix" : "published";
}

/** The `planned` label came or went. Tags only, so doing it twice does no harm. */
export async function applyPlanned(env: Env, number: number, planned: boolean): Promise<void> {
	await setPlanned(env.DB, number, planned, nowSeconds());
	const issue = await getIssue(env.DB, number);
	if (!issue || Boolean(issue.planned) !== planned || !inboxConfigured(env)) return;
	await showPlanned(env, new DiscordBot(env.DISCORD_BOT_TOKEN), issue);
}

/** The issue was renamed on GitHub: so is its post. */
export async function applyRename(env: Env, number: number, title: string): Promise<void> {
	await renameIssue(env.DB, number, title, nowSeconds());
	const issue = await getIssue(env.DB, number);
	if (!issue || issue.title !== title || !inboxConfigured(env)) return;
	await renamePost(new DiscordBot(env.DISCORD_BOT_TOKEN), issue);
}

/** Redraws the inbox messages of the reports counted into an issue — the newest few, within the free plan's calls. */
export async function redrawInbox(env: Env, number: number): Promise<void> {
	for (const report of await reportsForIssue(env.DB, number, LIMITS.redraws)) await refreshInbox(env, report);
}

// MARK: Telling Alex

function githubOn(env: Env): boolean {
	return Boolean(env.GITHUB_APP_CLIENT_ID && env.GITHUB_APP_PRIVATE_KEY);
}

async function tell(bot: DiscordBot, env: Env, target: ReplyTarget, content: string): Promise<void> {
	try {
		await bot.editReply(target.applicationId || env.DISCORD_APPLICATION_ID, target.token, outcome(content));
	} catch (error) {
		// The press's token lasts 15 minutes; past that, the inbox message still shows where things stand.
		logError("reply.edit_failed", error);
	}
}

/** A failure in words Alex can act on. */
export function describe(error: unknown): string {
	if (error instanceof PublishError) return error.message;
	if (error instanceof GitHubError) {
		const hint: Record<number, string> = {
			401: "The App's key or client ID isn't right.",
			403: "The App isn't allowed to do that — check its permissions (Issues: write).",
			404: "Is the App installed on the repository?",
			410: "The issue was deleted.",
			422: "GitHub didn't take it as sent (a label or the issue type?).",
		};
		return `${error.message}.${hint[error.status] ? ` ${hint[error.status]}` : ""}`;
	}
	if (error instanceof DiscordError) {
		const hint: Record<number, string> = {
			10003: "The post or forum is gone.",
			40067: "The forum wants a tag the bot couldn't find — check the tags' names.",
			50001: "The bot can't see that forum.",
			50013: "The bot is missing a permission there (Send Messages, Attach Files, Manage Threads).",
			50083: "The post is archived.",
		};
		const extra = error.code !== null && hint[error.code] ? ` ${hint[error.code]}` : "";
		return `${error.message}.${extra}`;
	}
	return "Something went wrong — the Worker's log has the details.";
}
