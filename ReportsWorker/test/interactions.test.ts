import { env } from "cloudflare:workers";
import { afterEach, describe, expect, it, vi } from "vitest";
import { downloadLink } from "../src/files";
import { bugReport, create, fakeDiscord, interactionRequest, png, press, row, send, uploadRequest, zip } from "./helpers";

afterEach(() => {
	vi.restoreAllMocks();
});

async function reportWithFiles() {
	fakeDiscord();
	const created = await create(bugReport({ attachments: ["bundle", "screenshot"] }));
	await send(uploadRequest(created.id, "bundle", created.key, zip(5000)));
	await send(uploadRequest(created.id, "screenshot", created.key, png(7000)));
	return created;
}

describe("the inbox's buttons", () => {
	it("refuse a press Discord did not sign, or signed long ago", async () => {
		expect((await send(await interactionRequest({ type: 1 }, { tamper: true }))).status).toBe(401);
		const unsigned = new Request("https://reports.wingcord.app/discord", { method: "POST", body: "{}" });
		expect((await send(unsigned)).status).toBe(401);
		const old = await interactionRequest({ type: 1 }, { timestamp: Math.floor(Date.now() / 1000) - 3600 });
		expect((await send(old)).status).toBe(401);
	});

	it("answer Discord's check of the endpoint", async () => {
		const response = await send(await interactionRequest({ type: 1 }));
		expect(response.status).toBe(200);
		expect(await response.json()).toEqual({ type: 1 });
	});

	it("work only for the server's managers, in that server", async () => {
		const created = await reportWithFiles();
		for (const interaction of [
			press(`download:${created.id}`, "0"),
			press(`download:${created.id}`, String(1 << 5), "999"),
		]) {
			const response = await send(await interactionRequest(interaction));
			const body = await response.json<any>();
			expect(body.type).toBe(4);
			expect(body.data.flags).toBe(64);
			expect(body.data.content).toBe("Only the server's managers can do that.");
		}
		// Administrator alone is enough.
		const admin = await send(await interactionRequest(press(`download:${created.id}`, String(1 << 3))));
		expect((await admin.json<any>()).data.content).toContain("/v1/files/");
	});

	it("give ten-minute download links only the presser sees", async () => {
		const created = await reportWithFiles();
		const response = await send(await interactionRequest(press(`download:${created.id}`)));
		const body = await response.json<any>();
		expect(body.type).toBe(4);
		expect(body.data.flags).toBe(64);
		const links = [...(body.data.content as string).matchAll(/\((https:[^)]+)\)/g)].map((match) => match[1]!);
		expect(links).toHaveLength(2);

		const bundle = await send(new Request(links[0]!));
		expect(bundle.status).toBe(200);
		expect(bundle.headers.get("Content-Type")).toBe("application/zip");
		expect(bundle.headers.get("Content-Disposition")).toBe(`attachment; filename="${created.id}.zip"`);
		expect((await bundle.arrayBuffer()).byteLength).toBe(5000);

		const tampered = links[1]!.replace(/sig=(.)/, (_, c) => `sig=${c === "a" ? "b" : "a"}`);
		expect((await send(new Request(tampered))).status).toBe(403);
		const expired = await downloadLink(env, created.id, "bundle", Math.floor(Date.now() / 1000) - 3600);
		expect((await send(new Request(expired))).status).toBe(403);
		const otherPart = links[0]!.replace("/bundle?", "/screenshot?");
		expect((await send(new Request(otherPart))).status).toBe(403);
	});

	it("solve: the files are deleted and the message is redrawn without buttons", async () => {
		const created = await reportWithFiles();
		const response = await send(await interactionRequest(press(`solve:${created.id}`)));
		const body = await response.json<any>();
		expect(body.type).toBe(7);
		expect(body.data.components).toEqual([]);
		expect(body.data.embeds[0].color).toBe(0x80848e);
		const status = body.data.embeds[0].fields.find((field: any) => field.name === "Status");
		expect(status.value).toMatch(/^Solved by <@400000000000000004> <t:\d+:R>\.$/);
		expect(body.data.allowed_mentions).toEqual({ parse: [] });

		expect(await env.BUCKET.get(`bundles/${created.id}.zip`)).toBeNull();
		expect(await env.BUCKET.get(`screenshots/${created.id}.png`)).toBeNull();
		expect((await row(created.id))?.status).toBe("solved");

		// Pressing again changes nothing, and there is nothing left to download.
		const again = await send(await interactionRequest(press(`solve:${created.id}`)));
		expect((await again.json<any>()).type).toBe(7);
		const download = await send(await interactionRequest(press(`download:${created.id}`)));
		expect((await download.json<any>()).data.content).toBe("There is nothing to download.");
	});

	it("say so when the report is gone", async () => {
		const response = await send(await interactionRequest(press("solve:WC-ZZZZ")));
		expect((await response.json<any>()).data.content).toBe("That report is gone — it may have expired.");
	});
});
