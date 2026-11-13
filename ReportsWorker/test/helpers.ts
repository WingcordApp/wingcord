import { createExecutionContext, waitOnExecutionContext } from "cloudflare:test";
import { env } from "cloudflare:workers";
import { vi } from "vitest";
import worker from "../src/index";

export const ORIGIN = "https://reports.wingcord.app";

const encoder = new TextEncoder();

/** A request as the Worker receives one, with Cloudflare's properties typed (as the docs suggest). */
const IncomingRequest = Request<unknown, IncomingRequestCfProperties>;

/** Runs one request through the Worker and waits for its background work. */
export async function send(request: Request, environment: Env = env): Promise<Response> {
	const ctx = createExecutionContext();
	const response = await worker.fetch(new IncomingRequest(request), environment, ctx);
	await waitOnExecutionContext(ctx);
	return response;
}

let lastAddress = 0;
/** A fresh documentation-range address per request, so the burst limit stays out of tests that are not about it. */
export function nextAddress(): string {
	lastAddress += 1;
	return `198.51.${Math.floor(lastAddress / 250) % 250}.${lastAddress % 250}`;
}

let lastInstall = 0;
export function nextInstall(): string {
	lastInstall += 1;
	return lastInstall.toString(16).padStart(16, "0");
}

export function bugReport(overrides: Record<string, unknown> = {}): Record<string, unknown> {
	return {
		kind: "bug",
		summary: "The call went quiet after the Mac woke from sleep.",
		details: "1. Join a voice channel\n2. Close the lid for a minute\n3. Open it",
		area: "voice",
		origin: "menu",
		app: { version: "1.0", build: "42" },
		macOS: "27.3",
		model: "Mac17,2",
		chip: "Apple M5",
		install: nextInstall(),
		attachments: ["bundle"],
		...overrides,
	};
}

export function crashReport(fingerprint: string, overrides: Record<string, unknown> = {}): Record<string, unknown> {
	return bugReport({
		area: "crash",
		origin: "afterCrash",
		attachments: ["bundle"],
		crash: {
			kind: "crash",
			signal: "SIGSEGV",
			fingerprint,
			frames: ["0 Wingcord 0x1000 + 4096", "1 Wingcord 0x2000 + 8192", "2 libdispatch.dylib 0x3000 + 12"],
		},
		...overrides,
	});
}

export function createRequest(body: unknown, address = nextAddress()): Request {
	return new Request(`${ORIGIN}/v1/reports`, {
		method: "POST",
		headers: { "Content-Type": "application/json", "CF-Connecting-IP": address },
		body: JSON.stringify(body),
	});
}

export interface Created {
	id: string;
	key: string;
	upload: string[];
	repeat: boolean;
}

export async function create(body: unknown, environment: Env = env): Promise<Created> {
	const response = await send(createRequest(body), environment);
	if (response.status !== 201) throw new Error(`expected 201, got ${response.status}: ${await response.text()}`);
	return response.json<Created>();
}

export function zip(size = 2048): Uint8Array {
	const bytes = new Uint8Array(size);
	bytes.set([0x50, 0x4b, 0x03, 0x04]);
	return bytes;
}

export function png(size = 4096): Uint8Array {
	const bytes = new Uint8Array(size);
	bytes.set([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]);
	return bytes;
}

export function uploadRequest(id: string, part: string, key: string, bytes: Uint8Array, type?: string): Request {
	return new Request(`${ORIGIN}/v1/reports/${id}/${part}`, {
		method: "PUT",
		headers: {
			Authorization: `Bearer ${key}`,
			"Content-Type": type ?? (part === "bundle" ? "application/zip" : "image/png"),
			"Content-Length": String(bytes.byteLength),
		},
		body: bytes,
	});
}

// MARK: Discord and GitHub, faked

export interface DiscordCall {
	method: string;
	path: string;
	authorization: string | null;
	/** The JSON sent; for a multipart post, its `payload_json`. */
	body: any;
	/** A multipart post's file. */
	file?: { name: string; type: string; size: number };
}

export interface GitHubCall {
	method: string;
	path: string;
	authorization: string | null;
	body: any;
}

export interface FakeIssue {
	number: number;
	title: string;
	body: string;
	labels: string[];
	type: string | null;
	state: "open" | "closed";
	state_reason: string | null;
}

export interface Fakes {
	discord: DiscordCall[];
	github: GitHubCall[];
	issues: Map<number, FakeIssue>;
	/** Files Discord's CDN serves, by URL. */
	cdn: Map<string, Uint8Array>;
}

/** The forums' tags, one with a curly apostrophe as Discord's client may type it. */
export const TAGS = {
	bug: "700000000000000001",
	crash: "700000000000000002",
	fixed: "700000000000000003",
	wontfix: "700000000000000004",
	idea: "700000000000000011",
	planned: "700000000000000012",
	added: "700000000000000013",
	notPlanned: "700000000000000014",
};

function forumTags(forumId: string) {
	if (forumId === env.DISCORD_BUGS_FORUM_ID) {
		return [
			{ id: TAGS.bug, name: "Bug" },
			{ id: TAGS.crash, name: "Crash" },
			{ id: TAGS.fixed, name: "Fixed" },
			{ id: TAGS.wontfix, name: "Won’t Fix" },
		];
	}
	return [
		{ id: TAGS.idea, name: "Idea" },
		{ id: TAGS.planned, name: "Planned" },
		{ id: TAGS.added, name: "Added" },
		{ id: TAGS.notPlanned, name: "Not Planned" },
	];
}

/**
 * Answers the Worker's calls to Discord, its CDN and GitHub, and records
 * them. The Worker runs in the tests' own isolate, so a mock of the global
 * `fetch` is the one it calls. `discordFailures` makes the first Discord calls
 * answer 500; `failDiscord` and `failGitHub` fail the calls they pick.
 */
export function fakeServices(
	options: {
		discordFailures?: number;
		failDiscord?: (call: DiscordCall) => { status: number; code: number } | null;
		failGitHub?: (call: GitHubCall) => number | null;
	} = {},
): Fakes {
	const fakes: Fakes = { discord: [], github: [], issues: new Map(), cdn: new Map() };
	let nextId = 1;
	let nextIssue = 12;
	let failuresLeft = options.discordFailures ?? 0;
	const original = globalThis.fetch;
	vi.spyOn(globalThis, "fetch").mockImplementation(async (input, init) => {
		const request = new Request(input, init);
		const url = new URL(request.url);

		if (url.hostname === "cdn.discordapp.com" || url.hostname === "media.discordapp.net") {
			const bytes = fakes.cdn.get(request.url);
			return bytes ? new Response(bytes, { headers: { "Content-Type": "image/png" } }) : new Response("gone", { status: 404 });
		}

		if (url.hostname === "discord.com") {
			const call: DiscordCall = {
				method: request.method,
				path: url.pathname.replace("/api/v10", ""),
				authorization: request.headers.get("Authorization"),
				body: null,
			};
			if ((request.headers.get("Content-Type") ?? "").startsWith("multipart/form-data")) {
				const form = await request.formData();
				call.body = JSON.parse(String(form.get("payload_json")));
				const file = form.get("files[0]") as File | null;
				if (file) call.file = { name: file.name, type: file.type, size: file.size };
			} else if (request.method !== "GET") {
				call.body = await request.json();
			}
			fakes.discord.push(call);
			if (failuresLeft > 0) {
				failuresLeft -= 1;
				return Response.json({ code: 0, message: "Internal Server Error" }, { status: 500 });
			}
			const failure = options.failDiscord?.(call);
			if (failure) return Response.json({ code: failure.code, message: "refused" }, { status: failure.status });
			const forum = /^\/channels\/(\d+)$/.exec(call.path);
			if (forum && call.method === "GET") return Response.json({ id: forum[1], available_tags: forumTags(forum[1]!) });
			return Response.json({ id: `${900000000000000000n + BigInt(nextId++)}` });
		}

		if (url.hostname === "api.github.com") {
			const call: GitHubCall = {
				method: request.method,
				path: url.pathname,
				authorization: request.headers.get("Authorization"),
				body: request.method === "GET" ? null : await request.json(),
			};
			fakes.github.push(call);
			const status = options.failGitHub?.(call);
			if (status) return Response.json({ message: "refused" }, { status });

			const repository = `/repos/${env.GITHUB_REPOSITORY}`;
			if (call.path === `${repository}/installation`) return Response.json({ id: 77 });
			if (call.path === "/app/installations/77/access_tokens") {
				return Response.json(
					{ token: "ghs_test_installation_token", expires_at: new Date(Date.now() + 3600_000).toISOString() },
					{ status: 201 },
				);
			}
			if (call.path === `${repository}/issues` && call.method === "POST") {
				const issue: FakeIssue = {
					number: nextIssue++,
					title: call.body.title,
					body: call.body.body,
					labels: call.body.labels ?? [],
					type: call.body.type ?? null,
					state: "open",
					state_reason: null,
				};
				fakes.issues.set(issue.number, issue);
				return Response.json({ number: issue.number }, { status: 201 });
			}
			const one = new RegExp(`^${repository}/issues/(\\d+)$`).exec(call.path);
			const issue = one ? fakes.issues.get(Number(one[1])) : undefined;
			if (issue && call.method === "GET") return Response.json(issue);
			if (issue && call.method === "PATCH") {
				Object.assign(issue, call.body);
				return Response.json(issue);
			}
			return Response.json({ message: "Not Found" }, { status: 404 });
		}

		return original(input, init);
	});
	return fakes;
}

/** Discord alone, as the phase 5 tests use it. */
export function fakeDiscord(failures = 0): DiscordCall[] {
	return fakeServices({ discordFailures: failures }).discord;
}

// MARK: Interactions, signed as Discord signs them

function fromBase64(text: string): Uint8Array {
	return Uint8Array.from(atob(text), (character) => character.charCodeAt(0));
}

function toHex(buffer: ArrayBuffer): string {
	return [...new Uint8Array(buffer)].map((byte) => byte.toString(16).padStart(2, "0")).join("");
}

export async function interactionRequest(
	body: unknown,
	options: { timestamp?: number; tamper?: boolean } = {},
): Promise<Request> {
	const key = await crypto.subtle.importKey("pkcs8", fromBase64(env.TEST_SIGNING_KEY), { name: "Ed25519" }, false, [
		"sign",
	]);
	const timestamp = String(options.timestamp ?? Math.floor(Date.now() / 1000));
	const raw = JSON.stringify(body);
	const signed = encoder.encode(timestamp + raw);
	const signature = toHex(await crypto.subtle.sign({ name: "Ed25519" }, key, signed));
	return new Request(`${ORIGIN}/discord`, {
		method: "POST",
		headers: {
			"Content-Type": "application/json",
			"X-Signature-Ed25519": options.tamper ? signature.replace(/^./, (c) => (c === "0" ? "1" : "0")) : signature,
			"X-Signature-Timestamp": timestamp,
		},
		body: raw,
	});
}

export const PRESSER = "400000000000000004";
export const INTERACTION_TOKEN = "test-interaction-token";

/** A button press in the inbox by someone with Manage Server, unless `permissions` says otherwise. */
export function press(customId: string, permissions = String(1 << 5), guild = env.DISCORD_GUILD_ID) {
	return {
		type: 3,
		token: INTERACTION_TOKEN,
		application_id: env.DISCORD_APPLICATION_ID,
		guild_id: guild,
		member: { permissions, user: { id: PRESSER } },
		data: { custom_id: customId, component_type: 2 },
	};
}

/**
 * A form sent back: each value in a Label as Discord nests it — text for a
 * string, a checkbox for a boolean, a select (or files) for a list.
 */
export function submit(
	customId: string,
	values: Record<string, string | boolean | string[]>,
	options: { permissions?: string; user?: string; resolved?: unknown } = {},
) {
	const components = Object.entries(values).map(([id, value], index) => ({
		type: 18,
		id: index + 1,
		component:
			typeof value === "string"
				? { type: 4, id: 100 + index, custom_id: id, value }
				: typeof value === "boolean"
					? { type: 23, id: 100 + index, custom_id: id, value }
					: { type: 3, id: 100 + index, custom_id: id, values: value },
	}));
	return {
		type: 5,
		token: INTERACTION_TOKEN,
		application_id: env.DISCORD_APPLICATION_ID,
		guild_id: env.DISCORD_GUILD_ID,
		member: { permissions: options.permissions ?? String(1 << 5), user: { id: options.user ?? PRESSER } },
		data: { custom_id: customId, components, ...(options.resolved ? { resolved: options.resolved } : {}) },
	};
}

/** Sends an interaction through the Worker, signed, and returns Discord's answer. */
export async function interact(interaction: unknown): Promise<any> {
	const response = await send(await interactionRequest(interaction));
	return response.json();
}

// MARK: GitHub's events, signed as GitHub signs them

export async function githubEvent(
	event: string,
	payload: unknown,
	options: { secret?: string; tamper?: boolean } = {},
): Promise<Request> {
	const raw = JSON.stringify(payload);
	const key = await crypto.subtle.importKey(
		"raw",
		encoder.encode(options.secret ?? env.GITHUB_WEBHOOK_SECRET),
		{ name: "HMAC", hash: "SHA-256" },
		false,
		["sign"],
	);
	let signature = toHex(await crypto.subtle.sign("HMAC", key, encoder.encode(raw)));
	if (options.tamper) signature = signature.replace(/^./, (c) => (c === "0" ? "1" : "0"));
	return new Request(`${ORIGIN}/github`, {
		method: "POST",
		headers: {
			"Content-Type": "application/json",
			"X-GitHub-Event": event,
			"X-GitHub-Delivery": crypto.randomUUID(),
			"X-Hub-Signature-256": `sha256=${signature}`,
		},
		body: raw,
	});
}

/** An `issues` event for the published repository. */
export function issueEvent(action: string, number: number, extra: Record<string, unknown> = {}) {
	return {
		action,
		issue: { number, title: `Issue ${number}`, state_reason: null },
		repository: { full_name: env.GITHUB_REPOSITORY },
		sender: { login: "Alex4afk", type: "User" },
		...extra,
	};
}

/**
 * Empties the index. Storage is kept apart per test file, not per test, so
 * the files about publishing start each test from nothing — GitHub's fake
 * numbers its issues from 12 every time.
 */
export async function resetStorage(): Promise<void> {
	await env.DB.batch(
		["issues", "repeats", "keys", "reports", "counters"].map((table) => env.DB.prepare(`DELETE FROM ${table}`)),
	);
}

export async function row(id: string): Promise<Record<string, any> | null> {
	return env.DB.prepare("SELECT * FROM reports WHERE id = ?1").bind(id).first();
}
