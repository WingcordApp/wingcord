import { generateKeyPairSync } from "node:crypto";
import path from "node:path";
import { cloudflareTest, readD1Migrations } from "@cloudflare/vitest-plugin";
import { defineConfig } from "vitest/config";

// A key pair to sign test interactions with, as Discord signs real ones.
const { publicKey, privateKey } = generateKeyPairSync("ed25519");
const discordPublicKey = publicKey.export({ format: "der", type: "spki" }).subarray(-32).toString("hex");
const signingKey = privateKey.export({ format: "der", type: "pkcs8" }).toString("base64");

// The two required secrets, as test values. Set in the environment so
// Wrangler finds them when it loads the config, and again as bindings below,
// which win over a developer's own `.dev.vars`.
const secrets = { DISCORD_BOT_TOKEN: "test-bot-token", LINK_KEY: "test-link-key" };
Object.assign(process.env, secrets);

export default defineConfig({
	plugins: [
		cloudflareTest(async () => ({
			wrangler: { configPath: "./wrangler.jsonc" },
			miniflare: {
				bindings: {
					TEST_MIGRATIONS: await readD1Migrations(path.join(import.meta.dirname, "migrations")),
					TEST_SIGNING_KEY: signingKey,
					DISCORD_PUBLIC_KEY: discordPublicKey,
					DISCORD_APPLICATION_ID: "100000000000000001",
					DISCORD_GUILD_ID: "200000000000000002",
					DISCORD_INBOX_CHANNEL_ID: "300000000000000003",
					...secrets,
				},
			},
		})),
	],
	test: { setupFiles: ["./test/setup.ts"] },
});
