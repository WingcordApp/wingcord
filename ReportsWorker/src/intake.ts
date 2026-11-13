// `POST /v1/reports` and `GET /v1/reports/:id`: a report arriving, and a
// tester asking what became of it.
//
// A report comes in two steps: this JSON (the words, the Mac, the crash),
// then each announced part by `PUT` (files.ts). The answer to this one says
// which parts to send — none, for a crash already open in the inbox, which
// is counted rather than stored twice.

import { caps, LIMITS, nowSeconds, type Status } from "./config";
import { randomKey, sha256Hex } from "./crypto";
import { postInbox, publishedInfo, refreshInbox } from "./discord";
import { bearer, json, log, mediaType, problem, readLimited } from "./http";
import { addRepeat, countAttempt, findOpenCrash, insertReport, reportForKey } from "./store";
import { validateReport } from "./validate";

const decoder = new TextDecoder();

export async function handleCreate(request: Request, env: Env, ctx: ExecutionContext): Promise<Response> {
	// A burst per address first: the cheapest refusal, and nothing stored.
	const address = request.headers.get("CF-Connecting-IP") ?? "unknown";
	const { success } = await env.IP_LIMITER.limit({ key: `report:${address}` });
	if (!success) return problem(429, "slow_down", {}, { "Retry-After": "60" });

	if (mediaType(request) !== "application/json") return problem(415, "json_expected");
	const body = await readLimited(request, LIMITS.reportBytes);
	if (!body) return problem(413, "too_large", { limit: LIMITS.reportBytes });
	let raw: unknown;
	try {
		raw = JSON.parse(decoder.decode(body));
	} catch {
		return problem(400, "invalid_json");
	}
	const checked = validateReport(raw);
	if (!checked.ok) return problem(400, "invalid", { field: checked.field, problem: checked.problem });
	const input = checked.value;

	// The exact limits, once the report is known to be well formed.
	const now = nowSeconds();
	const allowance = await countAttempt(env.DB, input.install, now, caps(env));
	if (!allowance.allowed) {
		return problem(429, allowance.reason, {}, { "Retry-After": String(allowance.retryAfter) });
	}

	const key = randomKey();
	const keyHash = await sha256Hex(key);

	if (input.crash) {
		const open = await findOpenCrash(env.DB, input.crash.fingerprint, input.appBuild);
		if (open) {
			const counted = await addRepeat(env.DB, open.id, input, keyHash, now);
			ctx.waitUntil(refreshInbox(env, counted));
			log("report.repeat", { id: open.id, count: counted.count });
			return json({ id: open.id, key, upload: [], repeat: true }, { status: 201 });
		}
	}

	const id = await insertReport(env.DB, input, keyHash, now);
	log("report.created", {
		id,
		kind: input.kind,
		area: input.area,
		crash: input.crash?.kind ?? null,
		parts: input.attachments,
	});
	// Words only: the inbox can have it now. Otherwise the last part posts it.
	if (input.attachments.length === 0) ctx.waitUntil(postInbox(env, id));
	return json({ id, key, upload: input.attachments, repeat: false }, { status: 201 });
}

/** What a tester's app shows for a report it sent (D28) — nothing private. */
export async function handleStatus(request: Request, env: Env, id: string): Promise<Response> {
	const key = bearer(request);
	if (!key) return problem(401, "key_required");
	const found = await reportForKey(env.DB, await sha256Hex(key));
	if (!found || found.report.id !== id) return problem(404, "not_found");
	const report = found.report;
	// A report counted into an issue is followed there: its GitHub issue and its forum post (D28).
	const published = report.status === "open" || report.status === "solved" ? null : await publishedInfo(env, report);
	const links: { issue?: string; post?: string } = {};
	if (published) {
		links.issue = published.issueUrl;
		if (published.postUrl) links.post = published.postUrl;
	}
	return json({
		id: report.id,
		kind: report.kind,
		status: publicStatus(report.status),
		count: report.count,
		links,
	});
}

function publicStatus(status: Status): string {
	return status === "open" ? "received" : status;
}
