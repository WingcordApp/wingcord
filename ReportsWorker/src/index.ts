// Wingcord's reports service (docs/BUG-REPORTING.md §9).
//
//   POST /v1/reports                    a report's JSON → { id, key, upload }
//   PUT  /v1/reports/:id/bundle|screenshot   each announced part, with the key
//   GET  /v1/reports/:id                its status, with the key
//   GET  /v1/files/:id/bundle|screenshot     a signed ten-minute download link
//   POST /discord                       the inbox's buttons

import { handleScheduled } from "./cron";
import { handleDownload, handleUpload } from "./files";
import { logError, notAllowed, problem } from "./http";
import { handleCreate, handleStatus } from "./intake";
import { handleInteraction } from "./interactions";
import type { Part } from "./config";

const ID = "(WC-[0-9A-HJKMNP-TV-Z]{4,5})";
const REPORT = new RegExp(`^/v1/reports/${ID}$`);
const REPORT_PART = new RegExp(`^/v1/reports/${ID}/(bundle|screenshot)$`);
const FILE = new RegExp(`^/v1/files/${ID}/(bundle|screenshot)$`);

async function route(request: Request, env: Env, ctx: ExecutionContext): Promise<Response> {
	const url = new URL(request.url);
	const path = url.pathname;
	const method = request.method;

	if (path === "/v1/reports") return method === "POST" ? handleCreate(request, env, ctx) : notAllowed("POST");

	let match = REPORT_PART.exec(path);
	if (match) return method === "PUT" ? handleUpload(request, env, ctx, match[1]!, match[2] as Part) : notAllowed("PUT");

	match = REPORT.exec(path);
	if (match) return method === "GET" ? handleStatus(request, env, match[1]!) : notAllowed("GET");

	match = FILE.exec(path);
	if (match) return method === "GET" ? handleDownload(url, env, match[1]!, match[2] as Part) : notAllowed("GET");

	if (path === "/discord") return method === "POST" ? handleInteraction(request, env) : notAllowed("POST");

	if (path === "/" && method === "GET") {
		return new Response("Wingcord's reports. Send one from Wingcord: Help ▸ Report a Bug…\n", {
			headers: { "Content-Type": "text/plain; charset=utf-8" },
		});
	}
	return problem(404, "not_found");
}

export default {
	async fetch(request, env, ctx): Promise<Response> {
		try {
			return await route(request, env, ctx);
		} catch (error) {
			// The path holds at most a report id; the query (a link's signature) is left out.
			logError("request.failed", error, { path: new URL(request.url).pathname });
			return problem(500, "internal");
		}
	},
	async scheduled(controller, env, _ctx): Promise<void> {
		await handleScheduled(controller, env);
	},
} satisfies ExportedHandler<Env>;
