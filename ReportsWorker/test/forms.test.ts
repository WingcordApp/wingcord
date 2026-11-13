import { env } from "cloudflare:workers";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { readVersions } from "../src/forms";
import { fakeServices, interact, png, press, resetStorage, row, submit } from "./helpers";

const MEMBER = "800000000000000008";
const PICTURE = "https://cdn.discordapp.com/ephemeral-attachments/1/2/window.png";

beforeEach(async () => {
	await resetStorage();
});

afterEach(() => {
	vi.restoreAllMocks();
});

/** What a member sends from the bug form. */
function bugForm(values: Record<string, string | boolean | string[]> = {}, attachment?: Record<string, unknown>) {
	return submit(
		"report:bug",
		{
			summary: "Wingcord crashes when I open it.",
			details: "1. Open Wingcord",
			area: ["crash"],
			versions: "Wingcord 1.0 (42), macOS 27.3",
			...(attachment ? { screenshot: ["900"] } : {}),
			...values,
		},
		{
			permissions: "0",
			user: MEMBER,
			...(attachment ? { resolved: { attachments: { "900": { id: "900", ...attachment } } } } : {}),
		},
	);
}

function reportId(reply: any): string {
	return /\*\*(WC-[0-9A-Z]{4,5})\*\*/.exec(reply.data.content)![1]!;
}

describe("the pinned posts' form", () => {
	it("opens for anyone in the server — and nowhere else", async () => {
		fakeServices();
		const bug = await interact(press("guide:bug", "0"));
		expect(bug.type).toBe(9);
		expect(bug.data.custom_id).toBe("report:bug");
		expect(bug.data.components.map((field: any) => field.component.custom_id)).toEqual([
			"summary",
			"details",
			"area",
			"versions",
			"screenshot",
		]);
		const picture = bug.data.components[4].component;
		expect(picture).toMatchObject({ type: 19, required: false, min_values: 0, max_values: 1, file_types: [".png"] });

		const idea = await interact(press("guide:idea", "0"));
		expect(idea.data.custom_id).toBe("report:idea");
		expect(idea.data.components).toHaveLength(4);

		const elsewhere = await interact(press("guide:bug", "0", "999999999999999999"));
		expect(elsewhere.data.content).toBe("This only works in the Wingcord server.");
		const old = await interact(press("guide:poll", "0"));
		expect(old.data.content).toBe("That button is from an older version of this post.");
	});

	it("sends a report to the inbox with the sender's name, the versions read, and the picture", async () => {
		const fakes = fakeServices();
		fakes.cdn.set(PICTURE, png(6000));
		const reply = await interact(
			bugForm({}, { url: PICTURE, filename: "window.png", content_type: "image/png", size: 6000 }),
		);
		expect(reply.type).toBe(4);
		expect(reply.data.flags).toBe(64);
		expect(reply.data.content).toContain("It went to the developer only, with your Discord name");
		const id = reportId(reply);

		expect(await row(id)).toMatchObject({
			kind: "bug",
			origin: "discord",
			reporter: MEMBER,
			area: "crash",
			app_version: "1.0",
			app_build: "42",
			macos: "27.3",
			model: null,
			pending: "",
			screenshot_size: 6000,
			bundle_size: null,
			details: "1. Open Wingcord",
		});
		const stored = await env.BUCKET.get(`screenshots/${id}.png`);
		expect(stored?.size).toBe(6000);

		const inbox = fakes.discord.find((call) => call.path === `/channels/${env.DISCORD_INBOX_CHANNEL_ID}/messages`)!;
		const embed = inbox.body.embeds[0];
		expect(embed.fields.find((field: any) => field.name === "Sent by").value).toBe(`<@${MEMBER}>`);
		expect(embed.fields.find((field: any) => field.name === "Mac").value).toBe("Wingcord 1.0 (42) · macOS 27.3");
		expect(embed.fields.find((field: any) => field.name === "Files").value).toBe("Screenshot · 6 KB");
		expect(embed.footer.text).toBe("From the #bug-reports form");
		expect(inbox.body.allowed_mentions).toEqual({ parse: [] });
	});

	it("reads a version with no build number, and shows it so", async () => {
		const fakes = fakeServices();
		const reply = await interact(bugForm({ versions: "Wingcord 1.0" }));
		const report = await row(reportId(reply));
		expect(report).toMatchObject({ app_version: "1.0", app_build: "", macos: "", details: "1. Open Wingcord" });
		const inbox = fakes.discord.find((call) => call.path === `/channels/${env.DISCORD_INBOX_CHANNEL_ID}/messages`)!;
		expect(inbox.body.embeds[0].fields.find((field: any) => field.name === "Mac").value).toBe("Wingcord 1.0");
	});

	it("keeps versions it can't read as the sender wrote them", async () => {
		const fakes = fakeServices();
		const reply = await interact(bugForm({ versions: "the newest one, I think" }));
		const report = await row(reportId(reply));
		expect(report).toMatchObject({ app_version: "", app_build: "", macos: "" });
		expect(report?.details).toBe("1. Open Wingcord\n\nVersions, as written: the newest one, I think");
		const inbox = fakes.discord.find((call) => call.path === `/channels/${env.DISCORD_INBOX_CHANNEL_ID}/messages`)!;
		expect(inbox.body.embeds[0].fields.find((field: any) => field.name === "Mac").value).toBe("Wingcord version not given");
	});

	it("leaves out a picture that isn't a PNG within 4 MB, or that Discord no longer has", async () => {
		const fakes = fakeServices();
		const jpeg = await interact(bugForm({}, { url: PICTURE, filename: "photo.jpg", content_type: "image/jpeg", size: 9000 }));
		expect(jpeg.data.content).toContain("The picture was left out");
		expect(await row(reportId(jpeg))).toMatchObject({ pending: "", screenshot_size: null });

		const huge = await interact(bugForm({}, { url: PICTURE, filename: "big.png", content_type: "image/png", size: 5 * 1024 * 1024 }));
		expect(huge.data.content).toContain("The picture was left out");

		// Announced as a PNG, gone from Discord's CDN by the time it's fetched: the words still arrive.
		const gone = await interact(bugForm({}, { url: `${PICTURE}?gone`, filename: "window.png", content_type: "image/png", size: 100 }));
		const id = reportId(gone);
		expect(await row(id)).toMatchObject({ pending: "", screenshot_size: null });
		const posted = fakes.discord.filter((call) => call.path === `/channels/${env.DISCORD_INBOX_CHANNEL_ID}/messages`).at(-1)!;
		expect(posted.body.embeds[0].title).toContain(id);
		expect(posted.body.embeds[0].fields.find((field: any) => field.name === "Files").value).toBe("None — the words only.");
	});

	it("is limited per person, like an install", async () => {
		fakeServices();
		for (let sent = 0; sent < 5; sent++) expect((await interact(bugForm())).data.content).toContain("Thanks");
		const sixth = await interact(bugForm());
		expect(sixth.data.content).toBe("That's a few from you this hour — please send this one a little later.");
		// Someone else is not held back by it.
		const other = await interact(submit("report:bug", { summary: "Mine too." }, { permissions: "0", user: "800000000000000009" }));
		expect(other.data.content).toContain("Thanks");
	});

	it("takes an idea with words only, and needs the words", async () => {
		fakeServices();
		const idea = await interact(
			submit("report:idea", { summary: "Pin a chat to the sidebar", details: "", area: [] }, { permissions: "0", user: MEMBER }),
		);
		expect(idea.data.content).toContain("Ideas worth building get their own post here");
		expect(await row(reportId(idea))).toMatchObject({ kind: "idea", area: "other", origin: "discord" });
		const empty = await interact(submit("report:idea", { summary: "   " }, { permissions: "0", user: MEMBER }));
		expect(empty.data.content).toBe("Say what happened, then send it again.");
	});
});

describe("versions as people type them", () => {
	it("are read when they can be, and handed back when they can't", () => {
		expect(readVersions("Wingcord 1.0 (42), macOS 27.3")).toEqual({ app: "1.0", build: "42", macos: "27.3", asTyped: null });
		expect(readVersions("1.2.3 (512) on 27.4.1")).toEqual({ app: "1.2.3", build: "512", macos: "27.4.1", asTyped: null });
		expect(readVersions("macOS Tahoe 26.1 / Wingcord 0.9 (7)")).toEqual({ app: "0.9", build: "7", macos: "26.1", asTyped: null });
		// A version with no build number, as testers will write it: Wingcord is 1.0.
		expect(readVersions("Wingcord 1.2")).toEqual({ app: "1.2", build: "", macos: null, asTyped: null });
		expect(readVersions("1.0 on macOS 27.3")).toEqual({ app: "1.0", build: "", macos: "27.3", asTyped: null });
		expect(readVersions("1.0, 27.3")).toEqual({ app: "1.0", build: "", macos: "27.3", asTyped: null });
		expect(readVersions("wingcord v1.0.2")).toEqual({ app: "1.0.2", build: "", macos: null, asTyped: null });
		// macOS alone; what's left is nothing worth keeping.
		expect(readVersions("27.3")).toEqual({ app: null, build: null, macos: "27.3", asTyped: null });
		// Words that aren't versions are kept as written.
		expect(readVersions("1.0 but the beta one")).toEqual({ app: "1.0", build: "", macos: null, asTyped: "1.0 but the beta one" });
		expect(readVersions("")).toEqual({ app: null, build: null, macos: null, asTyped: null });
	});
});
