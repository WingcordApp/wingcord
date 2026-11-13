// The GitHub App's side: its tokens, the issues it makes and changes, and
// the check on the events GitHub sends back (D26, D27).
//
// **The App can touch one repository's issues and nothing else.** It asks for
// Issues (write) and Metadata (read) when it is made (scripts/github-app.py),
// and every token below is narrowed again to that one repository and to
// issues. Nothing is installed: the token is an RS256 JWT from Web Crypto.

import { GITHUB, LIMITS, nowSeconds } from "./config";
import { hmacHex, sameSecret, signJwt } from "./crypto";
import { readLimited } from "./http";

export class GitHubError extends Error {
	constructor(
		readonly status: number,
		readonly what: string,
	) {
		// GitHub's own message is left out: a refusal can quote what was sent.
		super(`GitHub answered ${status} to ${what}`);
	}
}

export function githubConfigured(env: Env): boolean {
	return Boolean(env.GITHUB_APP_CLIENT_ID && env.GITHUB_APP_PRIVATE_KEY && env.GITHUB_REPOSITORY);
}

export function issueUrl(env: Env, number: number): string {
	return `${GITHUB.web}/${env.GITHUB_REPOSITORY}/issues/${number}`;
}

export interface NewIssue {
	title: string;
	body: string;
	labels: string[];
	/** The organization's issue type: Bug or Feature. */
	type: string;
}

export interface IssueChanges {
	title?: string;
	body?: string;
	state?: "open" | "closed";
	state_reason?: "completed" | "not_planned" | "duplicate" | "reopened";
}

/**
 * An installation token lives an hour; this one is kept for the isolate's
 * life, until five minutes before it ends. Keyed by the App and repository,
 * so a test's environment never borrows another's.
 */
let cached: { owner: string; token: string; expiresAt: number } | null = null;

/** For tests: forget the token, as a new isolate would. */
export function forgetGitHubToken(): void {
	cached = null;
}

/** The App's own token: ten minutes at most, dated a minute back for clock drift (GitHub's advice). */
export async function appJwt(env: Env, now = nowSeconds()): Promise<string> {
	return signJwt(env.GITHUB_APP_PRIVATE_KEY, { iat: now - 60, exp: now + 9 * 60, iss: env.GITHUB_APP_CLIENT_ID });
}

export class GitHub {
	constructor(private readonly env: Env) {}

	/** Makes an issue and returns its number. */
	async createIssue(issue: NewIssue): Promise<number> {
		const response = await this.call("POST", `/repos/${this.env.GITHUB_REPOSITORY}/issues`, issue, "creating an issue");
		const created = await response.json<{ number: number }>();
		return created.number;
	}

	async getIssue(number: number): Promise<{ title: string; body: string | null; state: string }> {
		const response = await this.call("GET", `/repos/${this.env.GITHUB_REPOSITORY}/issues/${number}`, null, "reading an issue");
		return response.json<{ title: string; body: string | null; state: string }>();
	}

	async updateIssue(number: number, changes: IssueChanges): Promise<void> {
		const response = await this.call(
			"PATCH",
			`/repos/${this.env.GITHUB_REPOSITORY}/issues/${number}`,
			changes,
			"changing an issue",
		);
		await response.body?.cancel();
	}

	private async token(): Promise<string> {
		const owner = `${this.env.GITHUB_APP_CLIENT_ID}/${this.env.GITHUB_REPOSITORY}`;
		const now = nowSeconds();
		if (cached && cached.owner === owner && cached.expiresAt - 5 * 60 > now) return cached.token;

		const jwt = await appJwt(this.env, now);
		const installation = await this.request("GET", `/repos/${this.env.GITHUB_REPOSITORY}/installation`, null, jwt);
		if (!installation.ok) throw new GitHubError(installation.status, "finding the App's installation");
		const { id } = await installation.json<{ id: number }>();

		const repository = this.env.GITHUB_REPOSITORY.split("/")[1]!;
		const minted = await this.request(
			"POST",
			`/app/installations/${id}/access_tokens`,
			{ repositories: [repository], permissions: { issues: "write" } },
			jwt,
		);
		if (!minted.ok) throw new GitHubError(minted.status, "making a token");
		const { token, expires_at } = await minted.json<{ token: string; expires_at: string }>();
		cached = { owner, token, expiresAt: Math.floor(Date.parse(expires_at) / 1000) };
		return token;
	}

	private async call(method: string, path: string, body: unknown, what: string): Promise<Response> {
		const response = await this.request(method, path, body, await this.token());
		if (!response.ok) {
			await response.body?.cancel();
			// A token GitHub stopped taking (the App's key was replaced, say) is not kept.
			if (response.status === 401) cached = null;
			throw new GitHubError(response.status, what);
		}
		return response;
	}

	private request(method: string, path: string, body: unknown, bearer: string): Promise<Response> {
		const headers: Record<string, string> = {
			Accept: "application/vnd.github+json",
			Authorization: `Bearer ${bearer}`,
			"User-Agent": GITHUB.userAgent,
			"X-GitHub-Api-Version": GITHUB.version,
		};
		if (body !== null) headers["Content-Type"] = "application/json";
		return fetch(GITHUB.api + path, {
			method,
			headers,
			body: body === null ? undefined : JSON.stringify(body),
		});
	}
}

/**
 * An event's body, if GitHub signed it with the App's webhook secret
 * (`X-Hub-Signature-256: sha256=<HMAC of the body>`); null otherwise. Too
 * large a body is refused before it is read whole.
 */
export async function verifiedEvent(
	request: Request,
	env: Env,
): Promise<{ ok: true; body: Uint8Array } | { ok: false; status: number; error: string }> {
	if (!env.GITHUB_WEBHOOK_SECRET) return { ok: false, status: 503, error: "github_not_configured" };
	const signature = request.headers.get("X-Hub-Signature-256");
	if (!signature) return { ok: false, status: 401, error: "unsigned" };
	const body = await readLimited(request, LIMITS.webhookBytes);
	if (!body) return { ok: false, status: 413, error: "too_large" };
	const expected = `sha256=${await hmacHex(env.GITHUB_WEBHOOK_SECRET, body)}`;
	if (!(await sameSecret(signature, expected))) return { ok: false, status: 401, error: "bad_signature" };
	return { ok: true, body };
}
