import { describe, expect, it } from "vitest";
import { clip, escapeMarkdown, inboxMessage } from "../src/inbox";
import type { ReportRow } from "../src/store";
import { cleanText } from "../src/validate";

function report(overrides: Partial<ReportRow> = {}): ReportRow {
	return {
		id: "WC-4F2K",
		kind: "bug",
		status: "open",
		area: "voice",
		origin: "menu",
		summary: "It went quiet",
		details: null,
		app_version: "1.0",
		app_build: "42",
		macos: "27.3",
		model: "Mac17,2",
		chip: "Apple M5",
		crash_kind: null,
		signal: null,
		fingerprint: null,
		frames: null,
		install: "0123456789abcdef",
		pending: "",
		bundle_size: 214 * 1024,
		screenshot_size: null,
		count: 1,
		created_at: 1_763_000_000,
		last_seen_at: 1_763_000_000,
		inbox_message_id: null,
		inbox_claimed_at: null,
		issue_number: null,
		forum_post_id: null,
		closed_at: null,
		closed_by: null,
		publishing_at: null,
		reporter: null,
		...overrides,
	};
}

describe("what a tester typed, in the inbox", () => {
	it("cannot link, mention or format", () => {
		const escaped = escapeMarkdown("[free nitro](https://evil.example) <@123> @everyone **bold** `code` # Big");
		expect(escaped).not.toMatch(/(^|[^\\])\[/);
		expect(escaped).not.toMatch(/(^|[^\\])</);
		expect(escaped).not.toMatch(/(^|[^\\])@/);
		expect(escaped).not.toMatch(/(^|[^\\])\*/);
		expect(escaped).not.toMatch(/https:\/\//);
		expect(escaped).toContain("https\\://evil.example");
	});

	it("is cut without leaving a backslash to escape the ellipsis", () => {
		const cut = clip(escapeMarkdown("a".repeat(8) + "*".repeat(20)), 12);
		expect(cut.endsWith("…")).toBe(true);
		expect(cut).not.toMatch(/(^|[^\\])(\\\\)*\\…$/);
		expect(Array.from(cut).length).toBeLessThanOrEqual(12);
	});

	it("loses only what hides or reorders text", () => {
		expect(cleanText("  hi​‮ there⁩\r\n\n\n\n\nnext  ", 100)).toBe("hi there\n\n\nnext");
		expect(cleanText("👨‍👩‍👧 family", 100)).toBe("👨‍👩‍👧 family");
		expect(cleanText("😀😀😀", 2)).toBe("😀😀…");
	});
});

describe("the inbox message", () => {
	it("shows a crash's signal and frames, and its count", () => {
		const message = inboxMessage(
			report({
				crash_kind: "crash",
				signal: "SIGSEGV",
				frames: JSON.stringify(["0 Wingcord 0x1 + 1", "1 `evil` 0x2 + 2"]),
				count: 3,
				last_seen_at: 1_763_000_600,
			}),
			null,
			1_763_000_700,
		);
		const embed = message.embeds[0]!;
		expect(embed.title).toBe("💥 WC-4F2K · Voice");
		const crash = embed.fields.find((field) => field.name === "Crash")!;
		expect(crash.value).toBe("SIGSEGV\n```\n0 Wingcord 0x1 + 1\n1 'evil' 0x2 + 2\n```");
		expect(embed.fields.find((field) => field.name === "Seen 3 times")?.value).toBe("Last <t:1763000600:R>");
		expect(embed.fields.find((field) => field.name === "Mac")?.value).toBe(
			"Wingcord 1.0 (42) · macOS 27.3 · Mac17,2 · Apple M5",
		);
		expect(message.allowed_mentions).toEqual({ parse: [] });
	});

	it("keeps within Discord's limits however long the words are", () => {
		const long = "*".repeat(4000);
		const message = inboxMessage(report({ summary: long, details: long }), null, 1_763_000_000);
		const embed = message.embeds[0]!;
		expect(Array.from(embed.description ?? "").length).toBeLessThanOrEqual(4096);
		for (const field of embed.fields) expect(Array.from(field.value).length).toBeLessThanOrEqual(1024);
		const total =
			embed.title.length +
			(embed.description?.length ?? 0) +
			embed.fields.reduce((sum, field) => sum + field.name.length + field.value.length, 0) +
			(embed.footer?.text.length ?? 0);
		expect(total).toBeLessThanOrEqual(6000);
	});

	it("disables Download until there is something to download", () => {
		const message = inboxMessage(report({ bundle_size: null, pending: "bundle" }), null, 1_763_000_000);
		const download = message.components[0]!.components.find((button) => button.label === "Download")!;
		expect(download.disabled).toBe(true);
	});
});
