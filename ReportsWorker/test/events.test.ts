import { env } from "cloudflare:workers";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { forgetGitHubToken } from "../src/github";
import {
	TAGS,
	bugReport,
	create,
	fakeServices,
	githubEvent,
	interact,
	issueEvent,
	png,
	resetStorage,
	row,
	send,
	submit,
	uploadRequest,
	zip,
	type Fakes,
} from "./helpers";

beforeEach(async () => {
	forgetGitHubToken();
	await resetStorage();
});

afterEach(() => {
	vi.restoreAllMocks();
});

/** A report published as #12, its post made. */
async function published(kind: "bug" | "idea" = "bug") {
	const created = await create(bugReport({ kind, attachments: kind === "bug" ? ["bundle", "screenshot"] : [] }));
	if (kind === "bug") {
		await send(uploadRequest(created.id, "bundle", created.key, zip()));
		await send(uploadRequest(created.id, "screenshot", created.key, png()));
	}
	await interact(
		submit(`publish:${created.id}`, {
			title: kind === "idea" ? "Pin a chat to the sidebar" : "Calls go quiet after sleep",
			body: "The words.",
			details: "",
			area: ["voice"],
			screenshot: false,
		}),
	);
	const issue = await env.DB.prepare("SELECT * FROM issues WHERE number = 12").first<Record<string, any>>();
	expect(issue?.forum_post_id).toBeTruthy();
	return { report: created, postId: issue!.forum_post_id as string };
}

function onPost(fakes: Fakes, postId: string, from = 0) {
	return fakes.discord.slice(from).filter((call) => call.path === `/channels/${postId}` || call.path === `/channels/${postId}/messages`);
}

describe("GitHub's events", () => {
	it("are refused unless GitHub signed them with the App's secret", async () => {
		fakeServices();
		expect((await send(await githubEvent("issues", issueEvent("closed", 12), { tamper: true }))).status).toBe(401);
		expect((await send(await githubEvent("issues", issueEvent("closed", 12), { secret: "someone-else" }))).status).toBe(401);
		const unsigned = new Request("https://reports.wingcord.app/github", { method: "POST", body: "{}" });
		expect((await send(unsigned)).status).toBe(401);
		expect((await send(new Request("https://reports.wingcord.app/github"))).status).toBe(405);
	});

	it("answer the App's ping and installation, and leave alone issues the inbox didn't publish", async () => {
		const fakes = fakeServices();
		expect((await send(await githubEvent("ping", { zen: "Keep it logically awesome." }))).status).toBe(204);
		expect((await send(await githubEvent("installation", { action: "created" }))).status).toBe(204);
		expect((await send(await githubEvent("issues", issueEvent("closed", 404)))).status).toBe(204);
		const elsewhere = issueEvent("closed", 12, { repository: { full_name: "someone/else" } });
		expect((await send(await githubEvent("issues", elsewhere))).status).toBe(204);
		expect(fakes.discord).toEqual([]);
	});

	it("closed as not planned: the idea's post says so, tagged Not Planned, locked and archived", async () => {
		const fakes = fakeServices();
		const { report, postId } = await published("idea");
		const from = fakes.discord.length;
		const closed = issueEvent("closed", 12, { issue: { number: 12, state_reason: "not_planned" } });
		expect((await send(await githubEvent("issues", closed))).status).toBe(204);

		const calls = onPost(fakes, postId, from);
		expect(calls[0]!.body).toEqual({ archived: false, applied_tags: [TAGS.idea, TAGS.notPlanned] });
		expect(calls[1]!.body.content).toBe(
			"**Not planned** — closed on GitHub as [#12](https://github.com/WingcordApp/wingcord/issues/12).",
		);
		expect(calls[2]!.body).toEqual({ locked: true, archived: true });
		expect(await row(report.id)).toMatchObject({ status: "wontfix" });
	});

	it("closed as a duplicate: no verdict tag, the post points to GitHub, the files go", async () => {
		const fakes = fakeServices();
		const { report, postId } = await published();
		const from = fakes.discord.length;
		await send(await githubEvent("issues", issueEvent("closed", 12, { issue: { number: 12, state_reason: "duplicate" } })));
		const calls = onPost(fakes, postId, from);
		expect(calls[0]!.body.applied_tags).toEqual([TAGS.bug]);
		expect(calls[1]!.body.content).toContain("as a duplicate");
		// The tester's status stays Published: the issue links on to the one to follow.
		expect(await row(report.id)).toMatchObject({ status: "published", bundle_size: null });
		expect(await env.BUCKET.head(`bundles/${report.id}.zip`)).toBeNull();
	});

	it("reopened: the post is opened, untagged and told; the reports are published again", async () => {
		const fakes = fakeServices();
		const { report, postId } = await published();
		await send(await githubEvent("issues", issueEvent("closed", 12, { issue: { number: 12, state_reason: "completed" } })));
		expect(await row(report.id)).toMatchObject({ status: "fixed" });

		const from = fakes.discord.length;
		expect((await send(await githubEvent("issues", issueEvent("reopened", 12)))).status).toBe(204);
		const calls = onPost(fakes, postId, from);
		expect(calls[0]!.body).toEqual({ archived: false, locked: false, applied_tags: [TAGS.bug] });
		expect(calls[1]!.body.content).toBe("↩️ **Reopened** on GitHub as [#12](https://github.com/WingcordApp/wingcord/issues/12).");
		expect(await row(report.id)).toMatchObject({ status: "published", closed_at: null });
	});

	it("`planned` tags an idea's post Planned, and taking it off untags it; other labels change nothing", async () => {
		const fakes = fakeServices();
		const { postId } = await published("idea");
		let from = fakes.discord.length;
		await send(await githubEvent("issues", issueEvent("labeled", 12, { label: { name: "planned" } })));
		expect(onPost(fakes, postId, from).map((call) => call.body)).toEqual([{ applied_tags: [TAGS.idea, TAGS.planned] }]);

		from = fakes.discord.length;
		await send(await githubEvent("issues", issueEvent("labeled", 12, { label: { name: "priority: high" } })));
		expect(fakes.discord.length).toBe(from);

		await send(await githubEvent("issues", issueEvent("unlabeled", 12, { label: { name: "planned" } })));
		expect(onPost(fakes, postId, from).map((call) => call.body)).toEqual([{ applied_tags: [TAGS.idea] }]);
	});

	it("a renamed issue renames its post — opening a closed one for it", async () => {
		const fakes = fakeServices();
		const { postId } = await published();
		let from = fakes.discord.length;
		const renamed = issueEvent("edited", 12, { issue: { number: 12, title: "Calls go\nquiet after sleep on AirPods" }, changes: { title: { from: "x" } } });
		await send(await githubEvent("issues", renamed));
		expect(onPost(fakes, postId, from).map((call) => call.body)).toEqual([{ name: "Calls go quiet after sleep on AirPods" }]);

		// A body edit is not a rename.
		from = fakes.discord.length;
		await send(await githubEvent("issues", issueEvent("edited", 12, { changes: { body: { from: "x" } } })));
		expect(fakes.discord.length).toBe(from);

		await send(await githubEvent("issues", issueEvent("closed", 12, { issue: { number: 12, state_reason: "completed" } })));
		from = fakes.discord.length;
		const again = issueEvent("edited", 12, { issue: { number: 12, title: "Calls go quiet after sleep" }, changes: { title: { from: "y" } } });
		await send(await githubEvent("issues", again));
		expect(onPost(fakes, postId, from).map((call) => call.body)).toEqual([
			{ archived: false, name: "Calls go quiet after sleep" },
			{ archived: true },
		]);
	});

	it("a change Discord refused is tried again when GitHub redelivers the event — and said only once", async () => {
		let refuse = true;
		const fakes = fakeServices({
			failDiscord: (call) => (refuse && call.method === "POST" && call.body?.content?.includes("Fixed") ? { status: 500, code: 0 } : null),
		});
		const { report, postId } = await published();
		const closed = issueEvent("closed", 12, { issue: { number: 12, state_reason: "completed" } });

		expect((await send(await githubEvent("issues", closed))).status).toBe(500);
		// The state moved on GitHub's word; only the post is behind.
		expect(await row(report.id)).toMatchObject({ status: "fixed" });
		expect(await env.DB.prepare("SELECT state, post_state FROM issues WHERE number = 12").first()).toEqual({
			state: "fixed",
			post_state: "open",
		});

		refuse = false;
		expect((await send(await githubEvent("issues", closed))).status).toBe(204);
		expect((await send(await githubEvent("issues", closed))).status).toBe(204);
		const said = fakes.discord.filter(
			(call) => call.path === `/channels/${postId}/messages` && call.method === "POST" && call.body.content.includes("Fixed"),
		);
		// One refused, one taken; the third delivery found nothing to do.
		expect(said).toHaveLength(2);
		expect(await env.DB.prepare("SELECT post_state FROM issues WHERE number = 12").first()).toEqual({ post_state: "fixed" });
	});
});
