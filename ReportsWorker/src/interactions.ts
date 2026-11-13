// `POST /discord`: the inbox's buttons. Discord sends each press here (the
// app's Interactions Endpoint URL), signed with the app's Ed25519 key.
//
// Only someone who can manage the server may press them, and only in that
// server — the inbox is private already, and this does not rely on it.

import { LIMITS, PART_SPECS, nowSeconds, type Part } from "./config";
import { concat, verifyEd25519 } from "./crypto";
import { downloadLink, objectKeys } from "./files";
import { json, log, problem, readLimited } from "./http";
import { formatBytes, inboxMessage } from "./inbox";
import { getReport, latestRepeat, solveReport } from "./store";

const encoder = new TextEncoder();
const decoder = new TextDecoder();

const PING = 1;
const MESSAGE_COMPONENT = 3;
const PONG = 1;
const CHANNEL_MESSAGE = 4;
const UPDATE_MESSAGE = 7;
const EPHEMERAL = 1 << 6;

const ADMINISTRATOR = 1n << 3n;
const MANAGE_GUILD = 1n << 5n;

interface Interaction {
	type: number;
	guild_id?: string;
	member?: { permissions?: string; user?: { id: string } };
	data?: { custom_id?: string };
}

export async function handleInteraction(request: Request, env: Env): Promise<Response> {
	if (!env.DISCORD_PUBLIC_KEY) return problem(503, "discord_not_configured");

	const signature = request.headers.get("X-Signature-Ed25519");
	const timestamp = request.headers.get("X-Signature-Timestamp");
	if (!signature || !timestamp) return problem(401, "unsigned");
	const body = await readLimited(request, LIMITS.interactionBytes);
	if (!body) return problem(413, "too_large");
	const signed = concat(encoder.encode(timestamp), body);
	if (!(await verifyEd25519(env.DISCORD_PUBLIC_KEY, signature, signed))) return problem(401, "bad_signature");
	// A signed press is still refused once it is old, so a copy of one cannot be replayed later.
	if (Math.abs(nowSeconds() - Number(timestamp)) > LIMITS.interactionSkewSeconds) return problem(401, "stale");

	let interaction: Interaction;
	try {
		interaction = JSON.parse(decoder.decode(body)) as Interaction;
	} catch {
		return problem(400, "invalid_json");
	}

	if (interaction.type === PING) return json({ type: PONG });
	if (interaction.type !== MESSAGE_COMPONENT) return reply("That isn't something this app does.");
	if (interaction.guild_id !== env.DISCORD_GUILD_ID || !canManage(interaction.member?.permissions)) {
		return reply("Only the server's managers can do that.");
	}

	const [action, id] = (interaction.data?.custom_id ?? "").split(":");
	const report = id ? await getReport(env.DB, id) : null;
	if (!report) return reply("That report is gone — it may have expired.");

	switch (action) {
		case "download": {
			const parts: Part[] = [];
			if (report.bundle_size !== null) parts.push("bundle");
			if (report.screenshot_size !== null) parts.push("screenshot");
			if (report.status !== "open" || parts.length === 0) return reply("There is nothing to download.");
			const now = nowSeconds();
			const lines = await Promise.all(
				parts.map(async (part) => {
					const size = part === "bundle" ? report.bundle_size : report.screenshot_size;
					const name = `${report.id}${PART_SPECS[part].extension}`;
					return `[${name}](${await downloadLink(env, report.id, part, now)}) · ${formatBytes(size ?? 0)}`;
				}),
			);
			log("inbox.download", { id: report.id });
			return reply(`${lines.join("\n")}\nThese links work for 10 minutes, and only you can see them.`);
		}
		case "solve": {
			const by = interaction.member?.user?.id ?? "";
			if (await solveReport(env.DB, report.id, nowSeconds(), by)) {
				// Its files go the moment it is solved (§2, principle 4).
				await env.BUCKET.delete(objectKeys(report.id));
				log("report.solved", { id: report.id });
			}
			const solved = await getReport(env.DB, report.id);
			if (!solved) return reply("That report is gone.");
			const latest = solved.count > 1 ? await latestRepeat(env.DB, solved.id) : null;
			return json({ type: UPDATE_MESSAGE, data: inboxMessage(solved, latest, nowSeconds()) });
		}
		default:
			return reply("That button is from an older version of the inbox.");
	}
}

function canManage(permissions: string | undefined): boolean {
	if (!permissions || !/^\d+$/.test(permissions)) return false;
	const bits = BigInt(permissions);
	return (bits & ADMINISTRATOR) !== 0n || (bits & MANAGE_GUILD) !== 0n;
}

/** A reply only the presser sees. */
function reply(content: string): Response {
	return json({ type: CHANNEL_MESSAGE, data: { content, flags: EPHEMERAL, allowed_mentions: { parse: [] } } });
}
