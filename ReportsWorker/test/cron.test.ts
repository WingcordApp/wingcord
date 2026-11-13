import { createExecutionContext, createScheduledController, waitOnExecutionContext } from "cloudflare:test";
import { env } from "cloudflare:workers";
import { afterEach, describe, expect, it, vi } from "vitest";
import worker from "../src/index";
import { CRONS } from "../src/config";
import { bugReport, create, fakeDiscord, row, send, uploadRequest, zip } from "./helpers";

afterEach(() => {
	vi.restoreAllMocks();
});

async function runCron(cron: string): Promise<void> {
	const controller = createScheduledController({ scheduledTime: new Date(), cron });
	const ctx = createExecutionContext();
	await worker.scheduled(controller, env, ctx);
	await waitOnExecutionContext(ctx);
}

async function age(id: string, seconds: number): Promise<void> {
	await env.DB.prepare("UPDATE reports SET created_at = created_at - ?2, last_seen_at = last_seen_at - ?2 WHERE id = ?1")
		.bind(id, seconds)
		.run();
}

describe("every 15 minutes", () => {
	it("posts a report whose parts never came, saying so", async () => {
		const discord = fakeDiscord();
		const created = await create(bugReport());
		await runCron(CRONS.inbox);
		expect(discord).toHaveLength(0);

		await age(created.id, 16 * 60);
		await runCron(CRONS.inbox);
		expect(discord).toHaveLength(1);
		const files = discord[0]!.body.embeds[0].fields.find((field: any) => field.name === "Files");
		expect(files.value).toBe("Diagnostics · never arrived");

		// A late bundle still lands, and redraws the message rather than posting again.
		await send(uploadRequest(created.id, "bundle", created.key, zip()));
		expect(discord).toHaveLength(2);
		expect(discord[1]!.method).toBe("PATCH");
	});

	it("retries a post Discord refused", async () => {
		const discord = fakeDiscord(1);
		const created = await create(bugReport({ attachments: [] }));
		expect(discord).toHaveLength(1);
		expect((await row(created.id))?.inbox_message_id).toBeNull();

		await runCron(CRONS.inbox);
		expect(discord).toHaveLength(2);
		expect((await row(created.id))?.inbox_message_id).toMatch(/^\d+$/);
		await runCron(CRONS.inbox);
		expect(discord).toHaveLength(2);
	});
});

describe("every day", () => {
	it("removes a report and its files after 90 days", async () => {
		fakeDiscord();
		const created = await create(bugReport());
		await send(uploadRequest(created.id, "bundle", created.key, zip()));
		await age(created.id, 91 * 86400);

		await runCron(CRONS.daily);
		expect(await row(created.id)).toBeNull();
		expect(await env.BUCKET.get(`bundles/${created.id}.zip`)).toBeNull();
		const keys = await env.DB.prepare("SELECT count(*) AS n FROM keys WHERE report_id = ?1").bind(created.id).first<{ n: number }>();
		expect(keys?.n).toBe(0);
	});

	it("keeps a published report's links and drops its words", async () => {
		fakeDiscord();
		const created = await create(bugReport({ attachments: [] }));
		await env.DB.prepare("UPDATE reports SET status = 'published', issue_number = 12, forum_post_id = '5' WHERE id = ?1")
			.bind(created.id)
			.run();
		await age(created.id, 91 * 86400);

		await runCron(CRONS.daily);
		const kept = await row(created.id);
		expect(kept).toMatchObject({ status: "published", issue_number: 12, forum_post_id: "5", summary: null, install: null });
	});

	it("leaves a recent report alone", async () => {
		fakeDiscord();
		const created = await create(bugReport({ attachments: [] }));
		await age(created.id, 89 * 86400);
		await runCron(CRONS.daily);
		expect((await row(created.id))?.summary).not.toBeNull();
	});
});
