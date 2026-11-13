// What a published report says on GitHub: its labels, type and body (D26).
//
// **Public: the words as Alex left them in the Publish… form, the area, the
// versions and Macs it was seen on, a count, and the screenshot if he ticked
// it. Never: the log, crash files, the other system facts, the install.**
// Nothing private reaches this file — it is given an `IssueRow`, which holds
// only what was published.
//
// The words are Markdown here, as an issue's are, with two things defused:
// an @-mention (GitHub would notify whoever it names) and an HTML comment
// (the body's own markers are comments, and must stay the only ones).

import { AREA_LABELS, ISSUE_TYPES, LABELS } from "./config";
import { sightings, type IssueRow, type Sighting } from "./store";

const SEEN = "seen";
const LINKS = "links";

export function issueLabels(issue: Pick<IssueRow, "kind" | "crash" | "area">): string[] {
	const labels: string[] = [issue.kind === "idea" ? LABELS.idea : LABELS.bug];
	if (issue.crash) labels.push(LABELS.crash);
	const area = AREA_LABELS[issue.area];
	if (area) labels.push(area);
	return labels;
}

export function issueType(issue: Pick<IssueRow, "kind">): string {
	return ISSUE_TYPES[issue.kind];
}

/** The public copy of the tester's screenshot, outside the 90-day prefixes (D26). */
export function screenshotUrl(env: Env, reportId: string): string {
	return `${env.PUBLIC_ORIGIN}/v1/published/${reportId}.png`;
}

/** The whole body, as first made. `postUrl` is null until the forum post exists. */
export function issueBody(env: Env, issue: IssueRow, postUrl: string | null): string {
	const parts = [defuse(issue.body)];
	if (issue.details) parts.push(`### ${detailsHeading(issue)}\n\n${defuse(issue.details)}`);
	if (issue.screenshot) parts.push(`![The screenshot sent with the report](${screenshotUrl(env, issue.first_report)})`);
	parts.push(seenSection(issue));
	parts.push(linksSection(issue, postUrl));
	return parts.join("\n\n");
}

export function detailsHeading(issue: Pick<IssueRow, "kind">): string {
	return issue.kind === "idea" ? "How it would be used" : "Steps to reproduce";
}

/** The versions and Macs, and the count — the part Same as… rewrites. */
export function seenSection(issue: Pick<IssueRow, "kind" | "count" | "seen">): string {
	const lines = [marker(SEEN)];
	const seen = sightings(issue).filter((sighting) => sighting.app || sighting.macos);
	if (issue.kind === "bug" && seen.length) {
		lines.push("", "**Seen on**", "", ...seen.map((sighting) => `- ${sightingLine(sighting)}`));
	}
	lines.push("", countSentence(issue), marker(SEEN, true));
	return lines.join("\n");
}

/** Where it came from, and the forum post — the part made once the post exists. */
export function linksSection(issue: Pick<IssueRow, "first_report" | "origin">, postUrl: string | null): string {
	const from = issue.origin === "discord" ? "the Wingcord Discord server" : "Wingcord";
	let line = `Sent from ${from} as ${issue.first_report}`;
	if (postUrl) line += ` · [Talk about it in the Wingcord Discord server](${postUrl})`;
	return [marker(LINKS), "", "---", "", `<sub>${line}</sub>`, "", marker(LINKS, true)].join("\n");
}

/**
 * `body` with one of its marked sections replaced, or null when the markers
 * are gone (someone edited them out on GitHub — their edit is left alone).
 */
export function replaceSection(body: string, section: string, name: "seen" | "links"): string | null {
	const start = marker(name);
	const end = marker(name, true);
	const from = body.indexOf(start);
	const to = from < 0 ? -1 : body.indexOf(end, from);
	if (from < 0 || to < 0) return null;
	return body.slice(0, from) + section + body.slice(to + end.length);
}

export function countSentence(issue: Pick<IssueRow, "kind" | "count">): string {
	const times = issue.count === 1 ? "once" : `${issue.count} times`;
	return issue.kind === "idea" ? `Asked for ${times}.` : `Reported ${times}.`;
}

export function sightingLine(sighting: Sighting): string {
	const parts = [sighting.app ? `Wingcord ${sighting.app}` : "Wingcord (version not given)"];
	if (sighting.macos) parts.push(`macOS ${sighting.macos}`);
	if (sighting.mac) parts.push(sighting.mac);
	return parts.join(" · ");
}

/** An @-mention made inert with a zero-width space; an HTML comment's opening written as text. */
export function defuse(text: string): string {
	return text.replace(/<!--/g, "&lt;!--").replace(/(^|[^\w@`])@(?=[A-Za-z0-9])/g, "$1@​");
}

function marker(name: string, closing = false): string {
	return `<!-- ${closing ? "/" : ""}wingcord:${name} -->`;
}
