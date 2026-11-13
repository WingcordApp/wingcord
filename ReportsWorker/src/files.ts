// A report's parts in R2: the app's uploads, Alex's ten-minute download
// links, and their removal.
//
// **An upload streams straight into the bucket.** Holding a 5 MB body in
// memory and parsing it would spend the free plan's 10 ms of CPU; a stream
// with a declared length costs almost none. Its shape is checked once it is
// stored, by reading back its first bytes.

import { LIMITS, PART_SPECS, PARTS, nowSeconds, type Part } from "./config";
import { hmacHex, sameSecret, sha256Hex } from "./crypto";
import { showInInbox } from "./discord";
import { bearer, log, mediaType, noContent, problem } from "./http";
import { completePart, pendingParts, reportForKey } from "./store";

export function objectKey(id: string, part: Part): string {
	return `${part}s/${id}${PART_SPECS[part].extension}`;
}

export function objectKeys(id: string): string[] {
	return PARTS.map((part) => objectKey(id, part));
}

/** `PUT /v1/reports/:id/:part` — with the key the report was created with. */
export async function handleUpload(
	request: Request,
	env: Env,
	ctx: ExecutionContext,
	id: string,
	part: Part,
): Promise<Response> {
	const key = bearer(request);
	if (!key) return problem(401, "key_required");
	const owner = await reportForKey(env.DB, await sha256Hex(key));
	// One answer for "no such report" and "not your report".
	if (!owner || owner.report.id !== id || !owner.uploads) return problem(404, "not_found");
	if (!pendingParts(owner.report).includes(part)) return problem(409, "not_expected");

	const spec = PART_SPECS[part];
	if (mediaType(request) !== spec.contentType) return problem(415, "wrong_type", { expected: spec.contentType });
	const length = Number(request.headers.get("Content-Length"));
	if (!Number.isInteger(length) || length <= 0) return problem(411, "length_required");
	if (length > spec.limit) return problem(413, "too_large", { limit: spec.limit });
	if (!request.body) return problem(400, "empty");

	const where = objectKey(id, part);
	const stored = await env.BUCKET.put(where, request.body, {
		httpMetadata: { contentType: spec.contentType },
	});
	if (!stored) return problem(500, "not_stored");
	if (!(await startsWith(env.BUCKET, where, spec.magic))) {
		await env.BUCKET.delete(where);
		return problem(400, part === "bundle" ? "not_a_zip" : "not_a_png");
	}

	const done = await completePart(env.DB, id, part, stored.size);
	log("report.part", { id, part, size: stored.size });
	// The report is whole: the inbox gets it now (or redraws it, if the cron
	// already posted it while this part was late).
	if (done && done.pending === "") ctx.waitUntil(showInInbox(env, id));
	return noContent();
}

async function startsWith(bucket: R2Bucket, key: string, magic: readonly number[]): Promise<boolean> {
	const head = await bucket.get(key, { range: { offset: 0, length: magic.length } });
	if (!head) return false;
	const bytes = new Uint8Array(await head.arrayBuffer());
	return bytes.length === magic.length && magic.every((byte, index) => bytes[index] === byte);
}

// MARK: Download links

function linkMessage(id: string, part: Part, expires: number): string {
	return `${id}/${part}/${expires}`;
}

/** A link to one part, good for `LIMITS.downloadLinkSeconds`. */
export async function downloadLink(env: Env, id: string, part: Part, now = nowSeconds()): Promise<string> {
	const expires = now + LIMITS.downloadLinkSeconds;
	const signature = await hmacHex(env.LINK_KEY, linkMessage(id, part, expires));
	return `${env.PUBLIC_ORIGIN}/v1/files/${id}/${part}?exp=${expires}&sig=${signature}`;
}

/** `GET /v1/files/:id/:part?exp&sig` — what a Download link opens. */
export async function handleDownload(url: URL, env: Env, id: string, part: Part): Promise<Response> {
	const expires = Number(url.searchParams.get("exp"));
	const signature = url.searchParams.get("sig") ?? "";
	if (!Number.isInteger(expires) || expires < nowSeconds()) return problem(403, "link_expired");
	const expected = await hmacHex(env.LINK_KEY, linkMessage(id, part, expires));
	if (!(await sameSecret(signature, expected))) return problem(403, "bad_link");

	const object = await env.BUCKET.get(objectKey(id, part));
	if (!object) return problem(404, "gone");
	const headers = new Headers();
	object.writeHttpMetadata(headers);
	headers.set("Content-Length", String(object.size));
	headers.set("Content-Disposition", `attachment; filename="${id}${PART_SPECS[part].extension}"`);
	headers.set("Cache-Control", "private, no-store");
	headers.set("X-Content-Type-Options", "nosniff");
	return new Response(object.body, { headers });
}
