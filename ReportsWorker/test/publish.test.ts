import { env } from "cloudflare:workers";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { forgetGitHubToken } from "../src/github";
import {
	INTERACTION_TOKEN,
	PRESSER,
	TAGS,
	bugReport,
	crashReport,
	create,
	fakeServices,
	interact,
	png,
	press,
	resetStorage,
	row,
	send,
	submit,
	uploadRequest,
	zip,
	type Fakes,
} from "./helpers";

const REPLY = `/webhooks/${env.DISCORD_APPLICATION_ID}/${INTERACTION_TOKEN}/messages/@original`;
const ISSUES = `/repos/${env.GITHUB_REPOSITORY}/issues`;
const TESTER_WORDS = "The call went quiet after the Mac woke from sleep.";

beforeEach(async () => {
	forgetGitHubToken();
	await resetStorage();
});

afterEach(() => {
	vi.restoreAllMocks();
});

/** A bug with its diagnostics and screenshot in, and its inbox message posted. */
async function reportWithFiles(overrides: Record<string, unknown> = {}) {
	const created = await create(bugReport({ attachments: ["bundle", "screenshot"], ...overrides }));
	await send(uploadRequest(created.id, "bundle", created.key, zip(5000)));
	await send(uploadRequest(created.id, "screenshot", created.key, png(7000)));
	return created;
}

function publishAnswers(overrides: Record<string, string | boolean | string[]> = {}) {
	return {
		title: "Calls go quiet after the Mac sleeps",
		body: TESTER_WORDS,
		details: "1. Join a voice channel\n2. Close the lid for a minute",
		area: ["voice"],
		screenshot: true,
		...overrides,
	};
}

async function issueRow(number: number) {
	return env.DB.prepare("SELECT * FROM issues WHERE number = ?1").bind(number).first<Record<string, any>>();
}

function threadPost(fakes: Fakes) {
	return fakes.discord.find((call) => call.method === "POST" && /^\/channels\/\d+\/threads$/.test(call.path));
}

describe("Publish…", () => {
	it("opens a form holding the tester's words, for managers only", async () => {
		fakeServices();
		const created = await reportWithFiles();
		const form = await interact(press(`publish:${created.id}`));
		expect(form.type).toBe(9);
		expect(form.data.custom_id).toBe(`publish:${created.id}`);
		const fields = Object.fromEntries(form.data.components.map((field: any) => [field.component.custom_id, field.component]));
		expect(fields.title.value).toBe(TESTER_WORDS);
		expect(fields.body.value).toBe(TESTER_WORDS);
		expect(fields.details.value).toContain("Join a voice channel");
		expect(fields.area.options.find((option: any) => option.default).value).toBe("voice");
		expect(fields.screenshot).toEqual({ type: 23, custom_id: "screenshot", default: false });

		const refused = await interact(press(`publish:${created.id}`, "0"));
		expect(refused.data.content).toBe("Only the server's managers can do that.");
	});

	it("makes the issue and the post, each linking to the other — the screenshot public, the diagnostics never", async () => {
		const fakes = fakeServices();
		const created = await reportWithFiles({ install: "feedfacecafebeef4242" });
		const answer = await interact(submit(`publish:${created.id}`, publishAnswers()));
		expect(answer).toEqual({ type: 5, data: { flags: 64 } });

		// GitHub: the App's token, narrowed to the one repository and issues.
		const token = fakes.github.find((call) => call.path === "/app/installations/77/access_tokens")!;
		expect(token.body).toEqual({ repositories: ["wingcord"], permissions: { issues: "write" } });
		const made = fakes.github.find((call) => call.method === "POST" && call.path === ISSUES)!;
		expect(made.authorization).toBe("Bearer ghs_test_installation_token");
		expect(made.body.title).toBe("Calls go quiet after the Mac sleeps");
		expect(made.body.labels).toEqual(["bug", "area: voice"]);
		expect(made.body.type).toBe("Bug");
		expect(made.body.body).toContain(TESTER_WORDS);
		expect(made.body.body).toContain("### Steps to reproduce");
		expect(made.body.body).toContain("- Wingcord 1.0 (42) · macOS 27.3 · Mac17,2");
		expect(made.body.body).toContain(`${env.PUBLIC_ORIGIN}/v1/published/${created.id}.png`);

		// Discord: the post in #bug-reports, tagged, with the picture and a button to the issue.
		const post = threadPost(fakes)!;
		expect(post.path).toBe(`/channels/${env.DISCORD_BUGS_FORUM_ID}/threads`);
		expect(post.body.name).toBe("Calls go quiet after the Mac sleeps");
		expect(post.body.applied_tags).toEqual([TAGS.bug]);
		expect(post.body.message.allowed_mentions).toEqual({ parse: [] });
		expect(post.body.message.components[0].components[0].url).toBe("https://github.com/WingcordApp/wingcord/issues/12");
		expect(post.file).toEqual({ name: `${created.id}.png`, type: "image/png", size: 7000 });

		// The issue, edited to link the post.
		const linked = fakes.issues.get(12)!;
		expect(linked.body).toContain(`https://discord.com/channels/${env.DISCORD_GUILD_ID}/${(await issueRow(12))!.forum_post_id}`);

		// Nothing private went public: no log, no link to it, no install, no chip. (The
		// private inbox message, and Alex's own reply, may show them.)
		const install = (await row(created.id))!.install as string;
		const postId = (await issueRow(12))!.forum_post_id as string;
		const forum = [`/channels/${env.DISCORD_BUGS_FORUM_ID}`, `/channels/${postId}`];
		const outside = JSON.stringify([fakes.github, fakes.discord.filter((call) => forum.some((path) => call.path.startsWith(path)))]);
		expect(outside).toContain(TESTER_WORDS);
		for (const secret of ["/v1/files/", "bundles/", install, "Apple M5", ".zip"]) {
			expect(outside).not.toContain(secret);
		}

		// The screenshot's public copy, served to GitHub; the private one is untouched.
		const published = await send(new Request(`${env.PUBLIC_ORIGIN}/v1/published/${created.id}.png`));
		expect(published.status).toBe(200);
		expect(published.headers.get("Content-Type")).toBe("image/png");
		expect((await published.arrayBuffer()).byteLength).toBe(7000);
		expect(await env.BUCKET.head(`bundles/${created.id}.zip`)).not.toBeNull();

		// Alex is told, the inbox redrawn, the report published.
		const told = fakes.discord.find((call) => call.path === REPLY)!;
		expect(told.body.content).toContain("Published as [#12](https://github.com/WingcordApp/wingcord/issues/12)");
		expect(told.body.flags).toBe(4);
		const inbox = fakes.discord.filter((call) => call.path.startsWith(`/channels/${env.DISCORD_INBOX_CHANNEL_ID}/messages/`)).at(-1)!;
		expect(inbox.body.components[0].components.map((button: any) => button.label)).toEqual(["Download", "Solve"]);
		expect(inbox.body.embeds[0].fields.find((field: any) => field.name === "Published").value).toContain("[#12]");
		expect(await row(created.id)).toMatchObject({ status: "published", issue_number: 12, publishing_at: null });
		expect(await issueRow(12)).toMatchObject({ linked: 1, screenshot: 1, count: 1, state: "open" });
	});

	it("signs the App's token with its key, as GitHub checks it", async () => {
		const fakes = fakeServices();
		const created = await reportWithFiles();
		await interact(submit(`publish:${created.id}`, publishAnswers()));
		const lookup = fakes.github.find((call) => call.path.endsWith("/installation"))!;
		const jwt = lookup.authorization!.replace("Bearer ", "");
		const [head, body, signature] = jwt.split(".");
		const decode = (part: string) => Uint8Array.from(atob(part.replace(/-/g, "+").replace(/_/g, "/")), (c) => c.charCodeAt(0));
		const key = await crypto.subtle.importKey(
			"spki",
			Uint8Array.from(atob(env.TEST_GITHUB_PUBLIC_KEY), (c) => c.charCodeAt(0)),
			{ name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" },
			false,
			["verify"],
		);
		const valid = await crypto.subtle.verify(
			"RSASSA-PKCS1-v1_5",
			key,
			decode(signature!),
			new TextEncoder().encode(`${head}.${body}`),
		);
		expect(valid).toBe(true);
		const claims = JSON.parse(new TextDecoder().decode(decode(body!)));
		expect(claims.iss).toBe(env.GITHUB_APP_CLIENT_ID);
		expect(claims.exp - claims.iat).toBeLessThanOrEqual(600);
	});

	it("leaves the screenshot out unless it's ticked", async () => {
		const fakes = fakeServices();
		const created = await reportWithFiles();
		await interact(submit(`publish:${created.id}`, publishAnswers({ screenshot: false })));
		expect(threadPost(fakes)!.file).toBeUndefined();
		expect(fakes.issues.get(12)!.body).not.toContain("/v1/published/");
		expect(await env.BUCKET.head(`published/${created.id}.png`)).toBeNull();
		expect((await send(new Request(`${env.PUBLIC_ORIGIN}/v1/published/${created.id}.png`))).status).toBe(404);
	});

	it("posts an idea in #suggestions, and a crash with both its tags", async () => {
		const fakes = fakeServices();
		const idea = await create(bugReport({ kind: "idea", area: "messages", attachments: [] }));
		await interact(submit(`publish:${idea.id}`, publishAnswers({ area: ["messages"], details: "" })));
		const ideaPost = threadPost(fakes)!;
		expect(ideaPost.path).toBe(`/channels/${env.DISCORD_IDEAS_FORUM_ID}/threads`);
		expect(ideaPost.body.applied_tags).toEqual([TAGS.idea]);
		expect(fakes.issues.get(12)).toMatchObject({ labels: ["idea", "area: messages"], type: "Feature" });

		const crash = await create(crashReport("c".repeat(16)));
		await send(uploadRequest(crash.id, "bundle", crash.key, zip()));
		await interact(submit(`publish:${crash.id}`, publishAnswers({ area: ["crash"] })));
		const crashPost = fakes.discord.filter((call) => call.method === "POST" && call.path.endsWith("/threads")).at(-1)!;
		expect(crashPost.body.applied_tags).toEqual([TAGS.bug, TAGS.crash]);
		expect(fakes.issues.get(13)!.labels).toEqual(["bug", "crash"]);
	});

	it("finishes a publish that failed part-way without making a second issue", async () => {
		let failing = true;
		const fakes = fakeServices({
			failDiscord: (call) =>
				failing && call.method === "POST" && call.path.endsWith("/threads") ? { status: 403, code: 50013 } : null,
		});
		const created = await reportWithFiles();
		await interact(submit(`publish:${created.id}`, publishAnswers()));

		const told = fakes.discord.filter((call) => call.path === REPLY).at(-1)!;
		expect(told.body.content).toContain("Discord answered 403 (code 50013)");
		expect(told.body.content).toContain("Finish Publishing");
		expect(await row(created.id)).toMatchObject({ status: "open", issue_number: 12, publishing_at: null });
		const inbox = fakes.discord.filter((call) => call.path.startsWith(`/channels/${env.DISCORD_INBOX_CHANNEL_ID}/messages/`)).at(-1)!;
		expect(inbox.body.components[0].components[0].label).toBe("Finish Publishing");

		failing = false;
		const answer = await interact(press(`publish:${created.id}`));
		expect(answer.type).toBe(5);
		expect(fakes.github.filter((call) => call.method === "POST" && call.path === ISSUES)).toHaveLength(1);
		expect(fakes.discord.filter((call) => call.method === "POST" && call.path.endsWith("/threads"))).toHaveLength(2);
		// The issue was edited, not rewritten: read first, then only its links changed.
		expect(fakes.github.some((call) => call.method === "GET" && call.path === `${ISSUES}/12`)).toBe(true);
		expect(fakes.issues.get(12)!.body).toContain("https://discord.com/channels/");
		expect(await row(created.id)).toMatchObject({ status: "published", issue_number: 12 });
	});

	it("is refused once published, and while another press is publishing", async () => {
		fakeServices();
		const created = await reportWithFiles();
		await env.DB.prepare("UPDATE reports SET publishing_at = ?2 WHERE id = ?1").bind(created.id, Math.floor(Date.now() / 1000)).run();
		const busy = await interact(submit(`publish:${created.id}`, publishAnswers()));
		expect(busy.data.content).toBe("It's being published already.");
		await env.DB.prepare("UPDATE reports SET publishing_at = NULL WHERE id = ?1").bind(created.id).run();

		await interact(submit(`publish:${created.id}`, publishAnswers()));
		const again = await interact(submit(`publish:${created.id}`, publishAnswers()));
		expect(again.data.content).toBe(`${created.id} is already published as #12.`);
		const blank = await interact(submit(`publish:${(await create(bugReport({ attachments: [] }))).id}`, publishAnswers({ title: "  " })));
		expect(blank.data.content).toContain("A title and the words are both needed");
	});

	it("tells the tester where to follow it", async () => {
		fakeServices();
		const created = await reportWithFiles();
		const before = await send(new Request(`${env.PUBLIC_ORIGIN}/v1/reports/${created.id}`, { headers: { Authorization: `Bearer ${created.key}` } }));
		expect(await before.json()).toMatchObject({ status: "received", links: {} });

		await interact(submit(`publish:${created.id}`, publishAnswers()));
		const after = await send(new Request(`${env.PUBLIC_ORIGIN}/v1/reports/${created.id}`, { headers: { Authorization: `Bearer ${created.key}` } }));
		const status = await after.json<any>();
		expect(status.status).toBe("published");
		expect(status.links.issue).toBe("https://github.com/WingcordApp/wingcord/issues/12");
		expect(status.links.post).toMatch(new RegExp(`^https://discord.com/channels/${env.DISCORD_GUILD_ID}/\\d+$`));
	});
});

describe("Same as…", () => {
	async function publishedCrash(fakes: Fakes) {
		const first = await create(crashReport("d".repeat(16)));
		await send(uploadRequest(first.id, "bundle", first.key, zip()));
		await interact(submit(`publish:${first.id}`, publishAnswers({ area: ["crash"], screenshot: false })));
		expect(fakes.issues.get(12)).toBeDefined();
		return first;
	}

	it("offers the open issues, the one holding the same crash chosen", async () => {
		const fakes = fakeServices();
		await publishedCrash(fakes);
		// The same crash again: its first report is published, so this one is new.
		const second = await create(crashReport("d".repeat(16), { summary: "Crashed again when I opened settings." }));
		const form = await interact(press(`same:${second.id}`));
		expect(form.type).toBe(9);
		const select = form.data.components[0].component;
		expect(select.options).toEqual([
			{ label: "#12 · Calls go quiet after the Mac sleeps", value: "12", description: "Bug · Reported once", default: true },
		]);
		expect(form.data.components[1].component.required).toBe(false);
	});

	it("counts a report into an issue: the count and the Macs on both sides, none of its words", async () => {
		const fakes = fakeServices();
		await publishedCrash(fakes);
		const second = await create(
			crashReport("d".repeat(16), { summary: "My private words about #secret-server", macOS: "27.4", app: { version: "1.1", build: "45" } }),
		);
		const answer = await interact(submit(`same:${second.id}`, { issue: ["12"], number: "" }));
		expect(answer.type).toBe(5);

		expect(await row(second.id)).toMatchObject({ status: "published", issue_number: 12 });
		expect(await issueRow(12)).toMatchObject({ count: 2 });
		const body = fakes.issues.get(12)!.body;
		expect(body).toContain("Reported 2 times.");
		expect(body).toContain("- Wingcord 1.1 (45) · macOS 27.4 · Mac17,2");
		const postEdit = fakes.discord.filter((call) => call.method === "PATCH" && /^\/channels\/(\d+)\/messages\/\1$/.test(call.path)).at(-1)!;
		expect(postEdit.body.content).toContain("Seen in Wingcord 1.0 (42), 1.1 (45) on macOS 27.3, 27.4 · reported 2 times");
		expect(JSON.stringify([fakes.github, fakes.discord])).not.toContain("secret-server");
		const told = fakes.discord.filter((call) => call.path === REPLY).at(-1)!;
		expect(told.body.content).toBe("Counted into [#12](https://github.com/WingcordApp/wingcord/issues/12) — 2 times now.");
	});

	it("takes a number or a link, and refuses issues it didn't publish or that are closed", async () => {
		const fakes = fakeServices();
		await publishedCrash(fakes);
		const other = await create(bugReport({ attachments: [] }));
		expect((await interact(submit(`same:${other.id}`, { number: "#99" }))).data.content).toBe(
			"#99 wasn't published from the inbox — Same as… counts only into those.",
		);
		expect((await interact(submit(`same:${other.id}`, { number: "soon" }))).data.content).toBe("“soon” isn't an issue number.");
		await env.DB.prepare("UPDATE issues SET state = 'fixed' WHERE number = 12").run();
		expect((await interact(submit(`same:${other.id}`, { number: "12" }))).data.content).toContain("#12 is closed.");
		await env.DB.prepare("UPDATE issues SET state = 'open' WHERE number = 12").run();
		const linked = await interact(submit(`same:${other.id}`, { number: "https://github.com/WingcordApp/wingcord/issues/12" }));
		expect(linked.type).toBe(5);
		expect((await row(other.id))?.issue_number).toBe(12);
	});
});

describe("Solve on a published report", () => {
	it("closes its issue on GitHub, and the post, the reports and their files follow — once", async () => {
		const fakes = fakeServices();
		const created = await reportWithFiles();
		await interact(submit(`publish:${created.id}`, publishAnswers()));
		const postId = (await issueRow(12))!.forum_post_id as string;

		const answer = await interact(press(`solve:${created.id}`));
		expect(answer).toEqual({ type: 6 });
		expect(fakes.issues.get(12)).toMatchObject({ state: "closed", state_reason: "completed" });
		expect(await issueRow(12)).toMatchObject({ state: "fixed", post_state: "fixed" });
		expect(await row(created.id)).toMatchObject({ status: "fixed", bundle_size: null, closed_by: PRESSER });
		expect(await env.BUCKET.head(`bundles/${created.id}.zip`)).toBeNull();
		expect(await env.BUCKET.head(`screenshots/${created.id}.png`)).toBeNull();
		// The published copy stays: the issue still shows it.
		expect(await env.BUCKET.head(`published/${created.id}.png`)).not.toBeNull();

		const onPost = fakes.discord.filter((call) => call.path.startsWith(`/channels/${postId}`));
		expect(onPost.map((call) => `${call.method} ${call.body?.content ? "line" : JSON.stringify(call.body)}`)).toEqual([
			`PATCH ${JSON.stringify({ archived: false, applied_tags: [TAGS.bug, TAGS.fixed] })}`,
			"POST line",
			`PATCH ${JSON.stringify({ locked: true, archived: true })}`,
		]);
		expect(onPost[1]!.body.content).toBe(
			"✅ **Fixed** — closed on GitHub as [#12](https://github.com/WingcordApp/wingcord/issues/12). Thanks to everyone who reported it.",
		);
		const inbox = fakes.discord.filter((call) => call.path.startsWith(`/channels/${env.DISCORD_INBOX_CHANNEL_ID}/messages/`)).at(-1)!;
		expect(inbox.body.components).toEqual([]);
		expect(inbox.body.embeds[0].fields.find((field: any) => field.name === "Status").value).toMatch(/^Fixed by <@\d+> <t:\d+:R>\.$/);

		// GitHub's own event for that close arrives after: nothing is said twice.
		const before = fakes.discord.length;
		const { githubEvent, issueEvent } = await import("./helpers");
		const echo = await send(await githubEvent("issues", issueEvent("closed", 12, { issue: { number: 12, state_reason: "completed" } })));
		expect(echo.status).toBe(204);
		expect(fakes.discord.slice(before).filter((call) => call.path.startsWith(`/channels/${postId}`))).toEqual([]);
	});
});
