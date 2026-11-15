// `POST /github`: the App's events (D27). GitHub leads, Discord follows —
// an issue closed, reopened, labelled `planned` or renamed on GitHub changes
// its post, and one deleted or transferred away closes its post and hands
// its reports back to the inbox. Only issues the inbox published are
// touched; the rest (issues opened on GitHub directly, from its own forms)
// are none of this service's.
//
// A failure answers 500, so GitHub keeps the delivery and Alex can press
// Redeliver on the App's Advanced page: every change here is safe to repeat.

import { LABELS, LIMITS } from "./config";
import { verifiedEvent } from "./github";
import { logError, noContent, problem } from "./http";
import { clip } from "./inbox";
import { applyIssueState, applyPlanned, applyRemoval, applyRename, redrawInbox, redrawReports } from "./publish";
import { getIssue } from "./store";
import { cleanText } from "./validate";

interface IssueEvent {
	action?: string;
	issue?: { number?: number; title?: string; state_reason?: string | null };
	label?: { name?: string };
	changes?: { title?: unknown };
	repository?: { full_name?: string };
}

const decoder = new TextDecoder();

export async function handleGitHubEvent(request: Request, env: Env, ctx: ExecutionContext): Promise<Response> {
	const verified = await verifiedEvent(request, env);
	if (!verified.ok) return problem(verified.status, verified.error);

	// `ping` when the App is made, `installation` when it is installed, and the rest: nothing to do.
	if (request.headers.get("X-GitHub-Event") !== "issues") return noContent();

	let event: IssueEvent;
	try {
		event = JSON.parse(decoder.decode(verified.body)) as IssueEvent;
	} catch {
		return problem(400, "invalid_json");
	}
	if (event.repository?.full_name?.toLowerCase() !== env.GITHUB_REPOSITORY.toLowerCase()) return noContent();
	const number = event.issue?.number;
	if (!Number.isInteger(number) || !(await getIssue(env.DB, number!))) return noContent();

	try {
		switch (event.action) {
			case "closed":
				await applyIssueState(env, number!, closedAs(event.issue?.state_reason));
				break;
			case "reopened":
				await applyIssueState(env, number!, "open");
				break;
			case "labeled":
			case "unlabeled":
				if (event.label?.name?.toLowerCase() !== LABELS.planned) return noContent();
				await applyPlanned(env, number!, event.action === "labeled");
				break;
			case "edited": {
				if (!event.changes?.title || typeof event.issue?.title !== "string") return noContent();
				// A post's name is one line of at most 100 characters.
				const title = clip(cleanText(event.issue.title, 1000).replace(/\s+/g, " "), LIMITS.title);
				if (!title) return noContent();
				await applyRename(env, number!, title);
				break;
			}
			case "deleted":
			case "transferred": {
				// The issue is forgotten, so its reports are redrawn from the list it hands back.
				const freed = await applyRemoval(env, number!, event.action);
				ctx.waitUntil(redrawReports(env, freed));
				return noContent();
			}
			default:
				return noContent();
		}
	} catch (error) {
		logError("github.event_failed", error, { issue: number, action: event.action });
		return problem(500, "failed");
	}
	ctx.waitUntil(redrawInbox(env, number!));
	return noContent();
}

/** GitHub's close reasons: completed (also its default), not planned, a duplicate. */
function closedAs(reason: string | null | undefined): "fixed" | "wontfix" | "duplicate" {
	if (reason === "not_planned") return "wontfix";
	if (reason === "duplicate") return "duplicate";
	return "fixed";
}
