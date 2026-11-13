// The test-only bindings from vitest.config.ts. `env` from
// "cloudflare:workers" is typed as `Cloudflare.Env`, so they join it here —
// in the tests' program only.
declare namespace Cloudflare {
	interface Env {
		TEST_MIGRATIONS: import("cloudflare:test").D1Migration[];
		/** PKCS #8, base 64: the private half of DISCORD_PUBLIC_KEY. */
		TEST_SIGNING_KEY: string;
		/** SPKI, base 64: the public half of GITHUB_APP_PRIVATE_KEY. */
		TEST_GITHUB_PUBLIC_KEY: string;
	}
}
