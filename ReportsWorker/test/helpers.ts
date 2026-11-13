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

// MARK: Discord, faked

export interface DiscordCall {
	method: string;
	path: string;
	authorization: string | null;
	body: any;
}

/**
 * Answers the Worker's calls to discord.com and records them. The Worker
 * runs in the tests' own isolate, so a mock of the global `fetch` is the one
 * it calls. `failures` makes the first calls answer 500.
 */
export function fakeDiscord(failures = 0) {
	const calls: DiscordCall[] = [];
	let nextMessage = 1;
	let failuresLeft = failures;
	const original = globalThis.fetch;
	vi.spyOn(globalThis, "fetch").mockImplementation(async (input, init) => {
		const request = new Request(input, init);
		const url = new URL(request.url);
		if (url.hostname !== "discord.com") return original(input, init);
		calls.push({
			method: request.method,
			path: url.pathname.replace("/api/v10", ""),
			authorization: request.headers.get("Authorization"),
			body: request.method === "GET" ? null : await request.json(),
		});
		if (failuresLeft > 0) {
			failuresLeft -= 1;
			return Response.json({ code: 0, message: "Internal Server Error" }, { status: 500 });
		}
		return Response.json({ id: `${900000000000000000n + BigInt(nextMessage++)}` });
	});
	return calls;
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

/** A button press in the inbox by someone with Manage Server, unless `permissions` says otherwise. */
export function press(customId: string, permissions = String(1 << 5), guild = env.DISCORD_GUILD_ID) {
	return {
		type: 3,
		guild_id: guild,
		member: { permissions, user: { id: "400000000000000004" } },
		data: { custom_id: customId, component_type: 2 },
	};
}

export async function row(id: string): Promise<Record<string, any> | null> {
	return env.DB.prepare("SELECT * FROM reports WHERE id = ?1").bind(id).first();
}
