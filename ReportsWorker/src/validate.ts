// The report's JSON, checked field by field. **Everything the inbox shows
// that a tester did not type comes through a pattern or a list here**, so
// the address being public lets nobody put arbitrary text where only a
// version or an area belongs.

import { AREAS, LIMITS, ORIGINS, PARTS, type Area, type Kind, type Origin, type Part } from "./config";

export interface CrashInput {
	kind: "crash" | "hang";
	/** `SIGSEGV`; a freeze has none. */
	signal: string | null;
	/** Hex, made by the app from the top frames; equal fingerprints are one crash. */
	fingerprint: string;
	frames: string[];
}

export interface ReportInput {
	kind: Kind;
	summary: string;
	details: string | null;
	area: Area;
	origin: Origin;
	appVersion: string;
	appBuild: string;
	macOS: string;
	model: string | null;
	chip: string | null;
	install: string;
	crash: CrashInput | null;
	/** The parts the app will upload next. */
	attachments: Part[];
}

export type Validation =
	| { ok: true; value: ReportInput }
	| { ok: false; field: string; problem: string };

export const VERSION = /^\d{1,4}(\.\d{1,4}){0,3}$/;
export const BUILD = /^\d{1,9}$/;
export const MACOS = /^\d{1,3}(\.\d{1,3}){0,2}$/;
/** `Mac17,2`, `MacBookPro18,3`, `VirtualMac2,1`. */
const MODEL = /^[A-Za-z]{2,24}\d{1,3},\d{1,3}$/;
const CHIP = /^[A-Za-z0-9 ()®™.,@-]{1,64}$/;
const INSTALL = /^[0-9a-f]{16,64}$/;
const FINGERPRINT = /^[0-9a-f]{16,64}$/;
const SIGNAL = /^SIG[A-Z]{2,8}$/;
/** One frame of a stack, as the app prints it: printable ASCII. */
const FRAME = /^[\x20-\x7e]{1,200}$/;

export function validateReport(raw: unknown): Validation {
	if (!isRecord(raw)) return fail("body", "must be an object");

	const kind = raw.kind;
	if (kind !== "bug" && kind !== "idea") return fail("kind", "must be bug or idea");

	if (typeof raw.summary !== "string") return fail("summary", "required");
	const summary = cleanText(raw.summary, LIMITS.summary);
	if (!summary) return fail("summary", "required");

	let details: string | null = null;
	if (raw.details !== undefined && raw.details !== null) {
		if (typeof raw.details !== "string") return fail("details", "must be text");
		details = cleanText(raw.details, LIMITS.details) || null;
	}

	if (!oneOf(AREAS, raw.area)) return fail("area", "unknown area");
	if (!oneOf(ORIGINS, raw.origin)) return fail("origin", "unknown origin");

	const app = raw.app;
	if (!isRecord(app) || !matches(VERSION, app.version) || !matches(BUILD, app.build)) {
		return fail("app", "needs version and build");
	}
	if (!matches(MACOS, raw.macOS)) return fail("macOS", "not a macOS version");

	const model = optional(MODEL, raw.model);
	if (model === undefined) return fail("model", "not a Mac model");
	const chip = optional(CHIP, raw.chip);
	if (chip === undefined) return fail("chip", "not a chip name");

	if (!matches(INSTALL, raw.install)) return fail("install", "not an install id");

	let crash: CrashInput | null = null;
	if (raw.crash !== undefined && raw.crash !== null) {
		if (kind !== "bug") return fail("crash", "only a bug has a crash");
		const checked = validateCrash(raw.crash);
		if (typeof checked === "string") return fail("crash", checked);
		crash = checked;
	}

	const attachments = raw.attachments ?? [];
	if (!Array.isArray(attachments) || !attachments.every((part) => oneOf(PARTS, part))) {
		return fail("attachments", "unknown part");
	}
	if (new Set(attachments).size !== attachments.length) return fail("attachments", "a part twice");
	if (kind === "idea" && attachments.includes("bundle")) return fail("attachments", "an idea has no diagnostics");

	return {
		ok: true,
		value: {
			kind,
			summary,
			details,
			area: raw.area,
			origin: raw.origin,
			appVersion: app.version,
			appBuild: app.build,
			macOS: raw.macOS,
			model,
			chip,
			install: raw.install,
			crash,
			attachments: attachments as Part[],
		},
	};
}

function validateCrash(raw: unknown): CrashInput | string {
	if (!isRecord(raw)) return "must be an object";
	if (raw.kind !== "crash" && raw.kind !== "hang") return "kind must be crash or hang";
	const signal = optional(SIGNAL, raw.signal);
	if (signal === undefined) return "not a signal";
	if (!matches(FINGERPRINT, raw.fingerprint)) return "needs a fingerprint";
	const frames = raw.frames ?? [];
	if (!Array.isArray(frames) || frames.length > LIMITS.frames) return "too many frames";
	if (!frames.every((frame) => matches(FRAME, frame))) return "a frame is not printable";
	return { kind: raw.kind, signal, fingerprint: raw.fingerprint, frames: frames as string[] };
}

/**
 * Text as it may be shown: line breaks made plain, control characters and
 * the invisible ones that reorder or hide text removed, runs of blank lines
 * shortened, and cut at `limit` characters (not code units, so an emoji is
 * never halved).
 */
export function cleanText(value: string, limit: number): string {
	const cleaned = value
		.normalize("NFC")
		.replace(/\r\n?/g, "\n")
		// C0 and C1 controls but tab and newline; zero-width space; the bidi
		// overrides and isolates; the byte-order mark.
		.replace(/[\u0000-\u0008\u000b-\u001f\u007f-\u009f​‪-‮⁦-⁩﻿]/g, "")
		.replace(/\n{4,}/g, "\n\n\n")
		.trim();
	const characters = Array.from(cleaned);
	if (characters.length <= limit) return cleaned;
	return characters.slice(0, limit).join("").trimEnd() + "…";
}

function isRecord(value: unknown): value is Record<string, unknown> {
	return typeof value === "object" && value !== null && !Array.isArray(value);
}

function oneOf<T extends string>(list: readonly T[], value: unknown): value is T {
	return typeof value === "string" && (list as readonly string[]).includes(value);
}

function matches(pattern: RegExp, value: unknown): value is string {
	return typeof value === "string" && pattern.test(value);
}

/** The value, null when absent, undefined when present and wrong. */
function optional(pattern: RegExp, value: unknown): string | null | undefined {
	if (value === undefined || value === null) return null;
	return matches(pattern, value) ? value : undefined;
}

function fail(field: string, problem: string): Validation {
	return { ok: false, field, problem };
}
