// What a report may hold, and how much of it. The app's own limits match:
// `Sources/Wingcord/Reporting` (4,000 characters a field) and
// `Diagnostics/BugReport.swift` (the areas).

export const KINDS = ["bug", "idea"] as const;
export type Kind = (typeof KINDS)[number];

/** `BugArea`'s raw values, in the app's order. */
export const AREAS = [
	"messages",
	"voice",
	"video",
	"screenShare",
	"notifications",
	"profiles",
	"servers",
	"appearance",
	"settings",
	"performance",
	"crash",
	"signIn",
	"other",
] as const;
export type Area = (typeof AREAS)[number];

/** `BugArea.title`, as the inbox shows it. */
export const AREA_TITLES: Record<Area, string> = {
	messages: "Messages",
	voice: "Voice",
	video: "Video",
	screenShare: "Screen Share",
	notifications: "Notifications",
	profiles: "Profiles",
	servers: "Servers & Channels",
	appearance: "Appearance",
	settings: "Settings",
	performance: "Speed & Freezes",
	crash: "Crash",
	signIn: "Signing In",
	other: "Something Else",
};

/** Where the sheet was opened — what a sender may claim. `web` is the website's form (phase 8). */
export const ORIGINS = ["menu", "command", "settings", "afterCrash", "afterHang", "web"] as const;
/** …and `discord`: the pinned posts' form (phase 7), which only the Worker itself records. */
export type Origin = (typeof ORIGINS)[number] | "discord";

export const PARTS = ["bundle", "screenshot"] as const;
export type Part = (typeof PARTS)[number];

export const STATUSES = ["open", "solved", "published", "fixed", "wontfix"] as const;
export type Status = (typeof STATUSES)[number];

/** A published issue's state, as GitHub's events leave it (D27, D34). */
export const ISSUE_STATES = ["open", "fixed", "wontfix", "duplicate"] as const;
export type IssueState = (typeof ISSUE_STATES)[number];

// MARK: Publishing (phase 7)

/** GitHub's REST API, as the App calls it. */
export const GITHUB = {
	api: "https://api.github.com",
	web: "https://github.com",
	version: "2022-11-28",
	userAgent: "wingcord-reports (https://wingcord.app)",
} as const;

/** The organization's issue types (Bug, Feature and Task exist on WingcordApp). */
export const ISSUE_TYPES: Record<Kind, string> = { bug: "Bug", idea: "Feature" };

/** The repository's labels: `bug` `crash` `idea` `planned` exist; the area labels come with phase 7. */
export const LABELS = { bug: "bug", idea: "idea", crash: "crash", planned: "planned" } as const;

/** An area's label on GitHub. A crash has the `crash` label instead; "Something Else" has none. */
export const AREA_LABELS: Record<Area, string | null> = {
	messages: "area: messages",
	voice: "area: voice",
	video: "area: video",
	screenShare: "area: screen share",
	notifications: "area: notifications",
	profiles: "area: profiles",
	servers: "area: servers & channels",
	appearance: "area: appearance",
	settings: "area: settings",
	performance: "area: speed & freezes",
	crash: null,
	signIn: "area: signing in",
	other: null,
};

/**
 * The forums' tags by name, as they are in the server (§7): `#bug-reports`
 * has Bug, Crash, Fixed and Won't Fix; `#suggestions` Idea, Planned, Added
 * and Not Planned. Their ids are read from the forum when needed, and names
 * are matched without regard to case or the kind of apostrophe.
 */
export const FORUM_TAGS = {
	bug: "Bug",
	crash: "Crash",
	fixed: "Fixed",
	wontfix: "Won't Fix",
	idea: "Idea",
	planned: "Planned",
	added: "Added",
	notPlanned: "Not Planned",
} as const;

export interface PartSpec {
	contentType: string;
	extension: string;
	limit: number;
	/** The file's first bytes, checked once it is stored. */
	magic: readonly number[];
}

export const PART_SPECS: Record<Part, PartSpec> = {
	// The zip of report.txt, report.json, log.txt, crashes/ and system/.
	bundle: {
		contentType: "application/zip",
		extension: ".zip",
		limit: 5 * 1024 * 1024,
		magic: [0x50, 0x4b, 0x03, 0x04],
	},
	// The window, when the tester ticked it.
	screenshot: {
		contentType: "image/png",
		extension: ".png",
		limit: 4 * 1024 * 1024,
		magic: [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a],
	},
};

export const LIMITS = {
	/** The report's JSON: two fields of 4,000 characters fit many times over. */
	reportBytes: 64 * 1024,
	/** A Discord interaction. */
	interactionBytes: 64 * 1024,
	summary: 4000,
	details: 4000,
	frames: 12,
	/** How long an interaction's timestamp stays believable. */
	interactionSkewSeconds: 5 * 60,
	/** A Download link's life. */
	downloadLinkSeconds: 10 * 60,
	/** After this, the inbox gets a report whose parts never came. */
	partsGraceSeconds: 15 * 60,
	/** A post that was claimed and never finished is retried after this. */
	inboxClaimSeconds: 10 * 60,
	retentionDays: 90,
	/** A post's name on Discord, and so the issue's title. */
	title: 100,
	/** A form's text field (Discord's own limit). */
	formText: 4000,
	/** A GitHub event: an issue's is tens of KB. */
	webhookBytes: 1024 * 1024,
	/** How long a press of Publish… holds its report. */
	publishClaimSeconds: 120,
	/** Inbox messages redrawn after one change to an issue — the free plan allows 50 calls out. */
	redraws: 20,
	/** The Macs listed under "Seen on". */
	seen: 20,
	/** The open issues Same as… offers (a select holds 25). */
	sameAsChoices: 25,
} as const;

/** The two crons in wrangler.jsonc. */
export const CRONS = {
	inbox: "*/15 * * * *",
	daily: "17 3 * * *",
} as const;

export interface Caps {
	installHourly: number;
	daily: number;
}

export function caps(env: Env): Caps {
	return {
		installHourly: positive(env.INSTALL_HOURLY_CAP, 5),
		daily: positive(env.DAILY_CAP, 200),
	};
}

function positive(text: string | undefined, fallback: number): number {
	const value = Number(text);
	return Number.isInteger(value) && value > 0 ? value : fallback;
}

export function nowSeconds(): number {
	return Math.floor(Date.now() / 1000);
}
