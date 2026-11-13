// Responses, bounded reads and the service's own log lines.
//
// **The log names events and report ids, never words, installs or
// addresses** — invocation logs are off in wrangler.jsonc for the same reason.

export function json(body: unknown, init: ResponseInit = {}): Response {
	const headers = new Headers(init.headers);
	headers.set("Content-Type", "application/json; charset=utf-8");
	headers.set("Cache-Control", "no-store");
	return new Response(JSON.stringify(body), { ...init, headers });
}

/** An error the app can act on: a stable code, and sometimes a detail. */
export function problem(
	status: number,
	error: string,
	detail: Record<string, unknown> = {},
	headers: HeadersInit = {},
): Response {
	return json({ error, ...detail }, { status, headers });
}

export function noContent(): Response {
	return new Response(null, { status: 204, headers: { "Cache-Control": "no-store" } });
}

export function notAllowed(allowed: string): Response {
	return problem(405, "method_not_allowed", {}, { Allow: allowed });
}

/** The bearer token, if the request carries one. */
export function bearer(request: Request): string | null {
	const header = request.headers.get("Authorization") ?? "";
	const match = /^Bearer ([A-Za-z0-9_-]{16,128})$/.exec(header);
	return match?.[1] ?? null;
}

/** The media type without its parameters, lowercased. */
export function mediaType(request: Request): string {
	return (request.headers.get("Content-Type") ?? "").split(";")[0]!.trim().toLowerCase();
}

/**
 * The whole body, or null once it passes `limit` bytes — for the small
 * bodies (a report's JSON, an interaction). The declared length is checked
 * first, and the stream is still counted, since a length can be left out.
 */
export async function readLimited(request: Request, limit: number): Promise<Uint8Array | null> {
	const declared = Number(request.headers.get("Content-Length") ?? "0");
	if (declared > limit) return null;
	if (!request.body) return new Uint8Array();
	const reader = request.body.getReader();
	const chunks: Uint8Array[] = [];
	let total = 0;
	for (;;) {
		const { done, value } = await reader.read();
		if (done) break;
		total += value.byteLength;
		if (total > limit) {
			await reader.cancel();
			return null;
		}
		chunks.push(value);
	}
	const body = new Uint8Array(total);
	let offset = 0;
	for (const chunk of chunks) {
		body.set(chunk, offset);
		offset += chunk.byteLength;
	}
	return body;
}

export function log(event: string, fields: Record<string, unknown> = {}): void {
	console.log(JSON.stringify({ event, ...fields }));
}

export function logError(event: string, error: unknown, fields: Record<string, unknown> = {}): void {
	const message = error instanceof Error ? error.message : String(error);
	console.error(JSON.stringify({ event, error: message, ...fields }));
}
