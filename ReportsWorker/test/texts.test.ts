import { env } from "cloudflare:workers";
import { describe, expect, it } from "vitest";
import { postMessage, postTags, seenSummary, tagIds } from "../src/forum";
import { reportForm } from "../src/forms";
import { issueNumber, publishForm, suggestedTitle } from "../src/interactions";
import { countSentence, defuse, issueBody, issueLabels, replaceSection, seenSection } from "../src/issue";
import type { Modal } from "../src/modal";
import type { IssueRow, ReportRow } from "../src/store";

function issue(overrides: Partial<IssueRow> = {}): IssueRow {
	return {
		number: 12,
		kind: "bug",
		crash: 0,
		area: "voice",
		title: "Calls go quiet after the Mac sleeps",
		body: "The call went quiet after the Mac woke.",
		details: "1. Join a call\n2. Close the lid",
		first_report: "WC-4F2K",
		origin: "menu",
		screenshot: 0,
		forum_post_id: null,
		linked: 0,
		state: "open",
		post_state: "open",
		planned: 0,
		count: 1,
		seen: JSON.stringify([{ app: "1.0 (42)", macos: "27.3", mac: "Mac17,2" }]),
		created_at: 1_763_000_000,
		updated_at: 1_763_000_000,
		...overrides,
	};
}

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
		bundle_size: 1000,
		screenshot_size: 2000,
		count: 1,
		created_at: 1_763_000_000,
		last_seen_at: 1_763_000_000,
		inbox_message_id: "1",
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

/** Every string a form holds, against Discord's limits for it. */
function expectWithinLimits(form: Modal) {
	expect(Array.from(form.title).length).toBeLessThanOrEqual(45);
	expect(form.components.length).toBeGreaterThan(0);
	expect(form.components.length).toBeLessThanOrEqual(5);
	for (const field of form.components as any[]) {
		expect(field.type).toBe(18);
		expect(field.label.length).toBeLessThanOrEqual(45);
		if (field.description) expect(field.description.length).toBeLessThanOrEqual(100);
		const component = field.component;
		if (component.type === 4) {
			expect(component.max_length).toBeLessThanOrEqual(4000);
			if (component.value) expect(component.value.length).toBeLessThanOrEqual(component.max_length);
			if (component.placeholder) expect(component.placeholder.length).toBeLessThanOrEqual(100);
		}
		if (component.type === 3) {
			expect(component.options.length).toBeLessThanOrEqual(25);
			for (const option of component.options) {
				expect(option.label.length).toBeLessThanOrEqual(100);
				expect(option.value.length).toBeLessThanOrEqual(100);
				if (option.description) expect(option.description.length).toBeLessThanOrEqual(100);
			}
			expect(component.options.filter((option: any) => option.default).length).toBeLessThanOrEqual(1);
		}
	}
}

describe("an issue's labels", () => {
	it("say what it is, whether it crashed, and where", () => {
		expect(issueLabels(issue())).toEqual(["bug", "area: voice"]);
		expect(issueLabels(issue({ crash: 1, area: "crash" }))).toEqual(["bug", "crash"]);
		expect(issueLabels(issue({ kind: "idea", area: "messages" }))).toEqual(["idea", "area: messages"]);
		expect(issueLabels(issue({ area: "other" }))).toEqual(["bug"]);
	});
});

describe("an issue's body", () => {
	it("holds the words, the steps, the Macs and a count — and the screenshot only when published", () => {
		const body = issueBody(env, issue(), null);
		expect(body).toContain("The call went quiet after the Mac woke.");
		expect(body).toContain("### Steps to reproduce\n\n1. Join a call");
		expect(body).toContain("- Wingcord 1.0 (42) · macOS 27.3 · Mac17,2");
		expect(body).toContain("Reported once.");
		expect(body).toContain("Sent from Wingcord as WC-4F2K");
		expect(body).not.toContain("/v1/published/");
		expect(issueBody(env, issue({ screenshot: 1 }), null)).toContain(`${env.PUBLIC_ORIGIN}/v1/published/WC-4F2K.png`);
	});

	it("names an idea's count without Macs", () => {
		const body = issueBody(env, issue({ kind: "idea", count: 3, details: null }), null);
		expect(body).toContain("Asked for 3 times.");
		expect(body).not.toContain("Seen on");
		expect(body).not.toContain("###");
	});

	it("has sections Same as… and publishing can rewrite, and leaves a body alone without them", () => {
		const body = issueBody(env, issue(), null);
		const counted = replaceSection(body, seenSection(issue({ count: 4 })), "seen");
		expect(counted).toContain("Reported 4 times.");
		expect(counted).not.toContain("Reported once.");
		expect(counted?.split("wingcord:seen").length).toBe(3);
		expect(replaceSection("Alex rewrote it all", seenSection(issue()), "seen")).toBeNull();
	});

	it("can't mention anyone on GitHub, or fake the body's own markers", () => {
		expect(defuse("ping @octocat and @WingcordApp/team")).toBe("ping @​octocat and @​WingcordApp/team");
		expect(defuse("mail me at a@b.com")).toBe("mail me at a@b.com");
		expect(defuse("<!-- /wingcord:seen -->")).toBe("&lt;!-- /wingcord:seen -->");
		const body = issueBody(env, issue({ body: "<!-- wingcord:seen --> sneaky" }), null);
		expect(body.split("<!-- wingcord:seen -->").length).toBe(2);
	});

	it("counts in words", () => {
		expect(countSentence({ kind: "bug", count: 1 })).toBe("Reported once.");
		expect(countSentence({ kind: "idea", count: 2 })).toBe("Asked for 2 times.");
	});
});

describe("a forum post", () => {
	it("is plain text within 2,000 characters, with a button to its issue", () => {
		const long = "😀 [click](https://evil.example) <@123> ".repeat(200);
		const message = postMessage(issue({ body: long, details: long }), "https://github.com/WingcordApp/wingcord/issues/12");
		expect(message.content!.length).toBeLessThanOrEqual(2000);
		expect(message.content).not.toMatch(/(^|[^\\])\[click\]/);
		expect(message.content).not.toMatch(/https:\/\//);
		expect(message.content).toMatch(/\n-# Seen in Wingcord 1\.0 \(42\) on macOS 27\.3 · reported once$/);
		expect(message.allowed_mentions).toEqual({ parse: [] });
		expect((message.components as any)[0].components[0]).toEqual({
			type: 2,
			style: 5,
			label: "#12 on GitHub",
			url: "https://github.com/WingcordApp/wingcord/issues/12",
		});
	});

	it("sums up where it was seen", () => {
		const seen = JSON.stringify([
			{ app: "1.0 (42)", macos: "27.3", mac: null },
			{ app: "1.1 (45)", macos: "27.3", mac: null },
			{ app: "1.1 (45)", macos: "27.4", mac: "Mac17,2" },
		]);
		expect(seenSummary(issue({ seen, count: 5 }))).toBe("Seen in Wingcord 1.0 (42), 1.1 (45) on macOS 27.3, 27.4 · reported 5 times");
		expect(seenSummary(issue({ kind: "idea", count: 2 }))).toBe("Asked for 2 times");
		expect(seenSummary(issue({ seen: "[]" }))).toBe("Reported once");
	});

	it("wears what it is, then where it stands — matching tags however they're typed", () => {
		const ids = tagIds([
			{ id: "b", name: "Bug" },
			{ id: "c", name: "crash" },
			{ id: "f", name: "Fixed" },
			{ id: "w", name: "Won’t Fix" },
			{ id: "i", name: "Idea" },
			{ id: "p", name: "Planned" },
			{ id: "a", name: "Added" },
			{ id: "n", name: "Not Planned" },
		]);
		expect(postTags(issue(), ids)).toEqual(["b"]);
		expect(postTags(issue({ crash: 1, state: "fixed" }), ids)).toEqual(["b", "c", "f"]);
		expect(postTags(issue({ state: "wontfix" }), ids)).toEqual(["b", "w"]);
		expect(postTags(issue({ state: "duplicate" }), ids)).toEqual(["b"]);
		expect(postTags(issue({ kind: "idea", planned: 1 }), ids)).toEqual(["i", "p"]);
		expect(postTags(issue({ kind: "idea", planned: 1, state: "fixed" }), ids)).toEqual(["i", "a"]);
		expect(postTags(issue({ kind: "idea", state: "wontfix" }), ids)).toEqual(["i", "n"]);
		expect(postTags(issue(), new Map())).toEqual([]);
	});
});

describe("the forms", () => {
	it("stay within Discord's limits however long the tester's words are", () => {
		const long = `${"word ".repeat(30)}\n${"🙂".repeat(3000)}`;
		expectWithinLimits(publishForm(report({ summary: long, details: long })));
		expectWithinLimits(publishForm(report({ kind: "idea", screenshot_size: null })));
		expectWithinLimits(reportForm("bug"));
		expectWithinLimits(reportForm("idea"));
		expect(reportForm("bug").components).toHaveLength(5);
	});

	it("offer the screenshot only when there is one, and never ticked", () => {
		const withPicture = publishForm(report()).components as any[];
		expect(withPicture.at(-1).component).toEqual({ type: 23, custom_id: "screenshot", default: false });
		const without = publishForm(report({ screenshot_size: null })).components as any[];
		expect(without.some((field) => field.component.custom_id === "screenshot")).toBe(false);
	});

	it("start the title from the first line, cut at a word", () => {
		expect(suggestedTitle({ summary: "\n  The call went quiet  \nmore" })).toBe("The call went quiet");
		const title = suggestedTitle({ summary: "word ".repeat(40) });
		expect(Array.from(title).length).toBeLessThanOrEqual(100);
		expect(title.endsWith("word…")).toBe(true);
		expect(suggestedTitle({ summary: null })).toBe("");
	});

	it("read an issue number however it's given", () => {
		expect(issueNumber("12")).toBe(12);
		expect(issueNumber(" #12 ")).toBe(12);
		expect(issueNumber("https://github.com/WingcordApp/wingcord/issues/12#issuecomment-1")).toBe(12);
		expect(issueNumber("twelve")).toBeNull();
		expect(issueNumber("12345678")).toBeNull();
	});
});
