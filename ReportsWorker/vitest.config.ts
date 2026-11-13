import { generateKeyPairSync } from "node:crypto";
import path from "node:path";
import { cloudflareTest, readD1Migrations } from "@cloudflare/vitest-plugin";
import { defineConfig } from "vitest/config";

// A key pair to sign test interactions with, as Discord signs real ones.
const { publicKey, privateKey } = generateKeyPairSync("ed25519");
const discordPublicKey = publicKey.export({ format: "der", type: "spki" }).subarray(-32).toString("hex");
const signingKey = privateKey.export({ format: "der", type: "pkcs8" }).toString("base64");

// A GitHub App key, in the PKCS #1 form GitHub hands out (`BEGIN RSA PRIVATE
// KEY`), and its public half for checking the App's tokens.
const app = generateKeyPairSync("rsa", { modulusLength: 2048 });
const githubAppKey = app.privateKey.export({ format: "pem", type: "pkcs1" }).toString();
const githubAppPublicKey = app.publicKey.export({ format: "der", type: "spki" }).toString("base64");

// The required secrets, as test values. Set in the environment so Wrangler
// finds them when it loads the config, and again as bindings below, which win
// over a developer's own `.dev.vars`.
const secrets = {
	DISCORD_BOT_TOKEN: "test-bot-token",
	LINK_KEY: "test-link-key",
	GITHUB_APP_PRIVATE_KEY: githubAppKey,
	GITHUB_WEBHOOK_SECRET: "test-webhook-secret",
};
Object.assign(process.env, secrets);

export default defineConfig({
	plugins: [
		cloudflareTest(async () => ({
			wrangler: { configPath: "./wrangler.jsonc" },
			miniflare: {
				bindings: {
					TEST_MIGRATIONS: await readD1Migrations(path.join(import.meta.dirname, "migrations")),
					TEST_SIGNING_KEY: signingKey,
					TEST_GITHUB_PUBLIC_KEY: githubAppPublicKey,
					DISCORD_PUBLIC_KEY: discordPublicKey,
					DISCORD_APPLICATION_ID: "100000000000000001",
					DISCORD_GUILD_ID: "200000000000000002",
					DISCORD_INBOX_CHANNEL_ID: "300000000000000003",
					DISCORD_BUGS_FORUM_ID: "500000000000000005",
					DISCORD_IDEAS_FORUM_ID: "600000000000000006",
					GITHUB_REPOSITORY: "WingcordApp/wingcord",
					GITHUB_APP_CLIENT_ID: "Iv23testclient",
					...secrets,
				},
			},
		})),
	],
	test: { setupFiles: ["./test/setup.ts"] },
});
