import { env } from "cloudflare:workers";
import { afterEach, describe, expect, it, vi } from "vitest";
import {
	ORIGIN,
	bugReport,
	crashReport,
	create,
	createRequest,
	fakeDiscord,
	nextInstall,
	png,
	row,
	send,
	uploadRequest,
	zip,
} from "./helpers";

afterEach(() => {
	vi.restoreAllMocks();
});

describe("a report arriving", () => {
	it("stores a bug, waits for its bundle, then posts it to the inbox once", async () => {
		const discord = fakeDiscord();
		const created = await create(bugReport());
		expect(created.id).toMatch(/^WC-[0-9A-HJKMNP-TV-Z]{4}$/);
		expect(created.upload).toEqual(["bundle"]);
		expect(created.repeat).toBe(false);
		expect((await row(created.id))?.pending).toBe("bundle");
		expect(discord).toHaveLength(0);

		const uploaded = await send(uploadRequest(created.id, "bundle", created.key, zip(3000)));
		expect(uploaded.status).toBe(204);
		const stored = await env.BUCKET.get(`bundles/${created.id}.zip`);
		expect(stored?.size).toBe(3000);
		const report = await row(created.id);
		expect(report?.pending).toBe("");
		expect(report?.bundle_size).toBe(3000);

		expect(discord).toHaveLength(1);
		const post = discord[0]!;
		expect(post.method).toBe("POST");
		expect(post.path).toBe(`/channels/${env.DISCORD_INBOX_CHANNEL_ID}/messages`);
		expect(post.authorization).toBe("Bot test-bot-token");
		expect(post.body.allowed_mentions).toEqual({ parse: [] });
		expect(post.body.embeds[0].title).toBe(`🐞 ${created.id} · Voice`);
		expect(post.body.components[0].components.map((button: any) => button.label)).toEqual([
			"Publish…",
			"Same as…",
			"Download",
			"Solve",
		]);
		expect(report?.inbox_message_id).toMatch(/^\d+$/);
	});

	it("posts an idea with words only at once", async () => {
		const discord = fakeDiscord();
		const created = await create(
			bugReport({ kind: "idea", area: "messages", summary: "Pin a chat to the sidebar", attachments: [] }),
		);
		expect(created.upload).toEqual([]);
		expect(discord).toHaveLength(1);
		expect(discord[0]!.body.embeds[0].title).toBe(`💡 ${created.id} · Messages`);
		expect(discord[0]!.body.embeds[0].footer.text).toBe("From Help ▸ Suggest a Feature…");
	});

	it("waits for every announced part before posting", async () => {
		const discord = fakeDiscord();
		const created = await create(bugReport({ attachments: ["bundle", "screenshot"] }));
		await send(uploadRequest(created.id, "screenshot", created.key, png()));
		expect(discord).toHaveLength(0);
		await send(uploadRequest(created.id, "bundle", created.key, zip()));
		expect(discord).toHaveLength(1);
		expect(discord[0]!.body.embeds[0].fields.find((field: any) => field.name === "Files").value).toBe(
			"Diagnostics · 2 KB\nScreenshot · 4 KB",
		);
	});

	it("refuses a malformed report, naming the field", async () => {
		const cases: [Record<string, unknown>, string][] = [
			[{ summary: "   " }, "summary"],
			[{ area: "everything" }, "area"],
			[{ origin: "telepathy" }, "origin"],
			[{ app: { version: "1.0" } }, "app"],
			[{ macOS: "Sequoia" }, "macOS"],
			[{ model: "<script>" }, "model"],
			[{ chip: "Apple M5\n@everyone" }, "chip"],
			[{ install: "not-hex" }, "install"],
			[{ attachments: ["bundle", "bundle"] }, "attachments"],
			[{ attachments: ["video"] }, "attachments"],
			[{ kind: "idea", attachments: ["bundle"] }, "attachments"],
			[{ kind: "idea", crash: { kind: "crash", fingerprint: "a".repeat(16) } }, "crash"],
		];
		for (const [overrides, field] of cases) {
			const response = await send(createRequest(bugReport(overrides)));
			expect(response.status, JSON.stringify(overrides)).toBe(400);
			expect(await response.json<{ field: string }>()).toMatchObject({ error: "invalid", field });
		}
		const frames = crashReport("b".repeat(16));
		(frames.crash as any).frames = ["0 Wingcord\u0007"];
		expect((await send(createRequest(frames))).status).toBe(400);
	});

	it("refuses what is not JSON, or too much of it", async () => {
		const notJSON = new Request(`${ORIGIN}/v1/reports`, {
			method: "POST",
			headers: { "Content-Type": "text/plain", "CF-Connecting-IP": "203.0.113.1" },
			body: "hello",
		});
		expect((await send(notJSON)).status).toBe(415);
		const huge = createRequest({ ...bugReport(), padding: "x".repeat(70 * 1024) });
		expect((await send(huge)).status).toBe(413);
		const broken = new Request(`${ORIGIN}/v1/reports`, {
			method: "POST",
			headers: { "Content-Type": "application/json", "CF-Connecting-IP": "203.0.113.2" },
			body: "{",
		});
		expect((await send(broken)).status).toBe(400);
	});

	it("keeps what a tester typed as typed, minus the invisible", async () => {
		fakeDiscord();
		const created = await create(
			bugReport({ summary: "Ab‮cd\u0000 é\r\nnext", details: "x".repeat(5000), attachments: [] }),
		);
		const report = await row(created.id);
		expect(report?.summary).toBe("Abcd é\nnext");
		expect(Array.from(report?.details as string)).toHaveLength(4001);
		expect((report?.details as string).endsWith("…")).toBe(true);
	});
});

describe("uploads", () => {
	it("take only the announced part, of its type and size, with the report's key", async () => {
		fakeDiscord();
		const created = await create(bugReport());
		const other = await create(bugReport());

		expect((await send(uploadRequest(created.id, "bundle", other.key, zip()))).status).toBe(404);
		expect((await send(uploadRequest(created.id, "screenshot", created.key, png()))).status).toBe(409);
		expect((await send(uploadRequest(created.id, "bundle", created.key, zip(), "text/plain"))).status).toBe(415);
		expect((await send(uploadRequest(created.id, "bundle", created.key, zip(5 * 1024 * 1024 + 1)))).status).toBe(413);

		const notZip = await send(uploadRequest(created.id, "bundle", created.key, png()));
		expect(notZip.status).toBe(400);
		expect(await notZip.json()).toMatchObject({ error: "not_a_zip" });
		expect(await env.BUCKET.get(`bundles/${created.id}.zip`)).toBeNull();

		expect((await send(uploadRequest(created.id, "bundle", created.key, zip()))).status).toBe(204);
		expect((await send(uploadRequest(created.id, "bundle", created.key, zip()))).status).toBe(409);
	});

	it("need a key at all", async () => {
		const created = await create(bugReport());
		const request = uploadRequest(created.id, "bundle", created.key, zip());
		request.headers.delete("Authorization");
		expect((await send(request)).status).toBe(401);
	});
});

describe("crashes", () => {
	it("count a repeat of an open crash into its report instead of storing it again", async () => {
		const discord = fakeDiscord();
		const first = await create(crashReport("c".repeat(16)));
		await send(uploadRequest(first.id, "bundle", first.key, zip()));
		expect(discord).toHaveLength(1);

		const second = await create(crashReport("c".repeat(16), { summary: "Crashed when I joined", model: "Mac15,3" }));
		expect(second.id).toBe(first.id);
		expect(second.repeat).toBe(true);
		expect(second.upload).toEqual([]);
		expect(second.key).not.toBe(first.key);

		const report = await row(first.id);
		expect(report?.count).toBe(2);
		// The inbox message is redrawn with the count and the latest words.
		expect(discord).toHaveLength(2);
		expect(discord[1]!.method).toBe("PATCH");
		const seen = discord[1]!.body.embeds[0].fields.find((field: any) => field.name === "Seen 2 times");
		expect(seen.value).toContain("Mac15,3");
		expect(seen.value).toContain("Crashed when I joined");
		expect(discord[1]!.body.embeds[0].title).toBe(`💥 ${first.id} · Crash`);

		// The second sender's key shows the same report.
		const status = await send(
			new Request(`${ORIGIN}/v1/reports/${first.id}`, { headers: { Authorization: `Bearer ${second.key}` } }),
		);
		expect(await status.json()).toMatchObject({ id: first.id, status: "received", count: 2 });
	});

	it("open a new report in another build, or once the first is solved", async () => {
		fakeDiscord();
		const first = await create(crashReport("d".repeat(16)));
		const otherBuild = await create(crashReport("d".repeat(16), { app: { version: "1.1", build: "43" } }));
		expect(otherBuild.id).not.toBe(first.id);

		await env.DB.prepare("UPDATE reports SET status = 'solved' WHERE id = ?1").bind(first.id).run();
		const again = await create(crashReport("d".repeat(16)));
		expect(again.id).not.toBe(first.id);
		expect(again.repeat).toBe(false);
	});
});

describe("limits", () => {
	it("refuse a sixth report from one Mac in an hour", async () => {
		const install = nextInstall();
		for (let index = 0; index < 5; index++) await create(bugReport({ install }));
		const sixth = await send(createRequest(bugReport({ install })));
		expect(sixth.status).toBe(429);
		expect(await sixth.json()).toMatchObject({ error: "too_many_from_this_mac" });
		expect(Number(sixth.headers.get("Retry-After"))).toBeGreaterThan(0);
	});

	it("refuse everyone once the day's total is reached", async () => {
		const day = new Date().toISOString().slice(0, 10);
		const current = await env.DB.prepare("SELECT count FROM counters WHERE name = ?1").bind(`day:${day}`).first<{ count: number }>();
		const strict = { ...env, DAILY_CAP: String((current?.count ?? 0) + 1) };
		await create(bugReport(), strict);
		const over = await send(createRequest(bugReport()), strict);
		expect(over.status).toBe(429);
		expect(await over.json()).toMatchObject({ error: "too_many_today" });
	});

	it("slow down a burst from one address", async () => {
		const address = "192.0.2.77";
		const statuses: number[] = [];
		for (let index = 0; index < 12; index++) {
			statuses.push((await send(createRequest(bugReport(), address))).status);
		}
		expect(statuses.slice(0, 10).every((status) => status === 201)).toBe(true);
		expect(statuses.at(-1)).toBe(429);
	});
});

describe("status", () => {
	it("opens with the report's key and says nothing private", async () => {
		const created = await create(bugReport());
		const other = await create(bugReport());
		const ask = (key: string) =>
			send(new Request(`${ORIGIN}/v1/reports/${created.id}`, { headers: { Authorization: `Bearer ${key}` } }));

		const mine = await ask(created.key);
		expect(mine.status).toBe(200);
		expect(await mine.json()).toEqual({ id: created.id, kind: "bug", status: "received", count: 1, links: {} });
		expect((await ask(other.key)).status).toBe(404);
		expect((await ask("x".repeat(43))).status).toBe(404);
		expect((await send(new Request(`${ORIGIN}/v1/reports/${created.id}`))).status).toBe(401);
	});
});

describe("routes", () => {
	it("answer unknown paths and wrong methods plainly", async () => {
		expect((await send(new Request(`${ORIGIN}/nope`))).status).toBe(404);
		const wrong = await send(new Request(`${ORIGIN}/v1/reports`));
		expect(wrong.status).toBe(405);
		expect(wrong.headers.get("Allow")).toBe("POST");
		expect((await send(new Request(`${ORIGIN}/`))).status).toBe(200);
	});
});
