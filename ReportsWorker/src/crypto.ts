// Ids, keys, hashes and signatures — all Web Crypto, nothing installed.

const encoder = new TextEncoder();

/** Crockford's base 32: no I, L, O or U to misread when a tester quotes it. */
const ALPHABET = "0123456789ABCDEFGHJKMNPQRSTVWXYZ";

/** `WC-4F2K`: short enough to read out, checked for collisions on insert. */
export function randomReportId(length = 4): string {
	const bytes = crypto.getRandomValues(new Uint8Array(length));
	let id = "WC-";
	// 32 divides 256, so masking keeps every symbol equally likely.
	for (const byte of bytes) id += ALPHABET[byte & 31];
	return id;
}

/** The tester's key to a report: 256 random bits. Only its hash is stored. */
export function randomKey(): string {
	return base64url(crypto.getRandomValues(new Uint8Array(32)));
}

export function base64url(bytes: Uint8Array): string {
	let binary = "";
	for (const byte of bytes) binary += String.fromCharCode(byte);
	return btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

export function hex(bytes: ArrayBuffer | Uint8Array): string {
	const view = bytes instanceof Uint8Array ? bytes : new Uint8Array(bytes);
	let text = "";
	for (const byte of view) text += byte.toString(16).padStart(2, "0");
	return text;
}

export function fromHex(text: string): Uint8Array | null {
	if (text.length % 2 !== 0 || !/^[0-9a-fA-F]*$/.test(text)) return null;
	const bytes = new Uint8Array(text.length / 2);
	for (let index = 0; index < bytes.length; index++) {
		bytes[index] = parseInt(text.slice(index * 2, index * 2 + 2), 16);
	}
	return bytes;
}

export async function sha256Hex(text: string): Promise<string> {
	return hex(await crypto.subtle.digest("SHA-256", encoder.encode(text)));
}

export async function hmacHex(secret: string, message: string): Promise<string> {
	const key = await crypto.subtle.importKey(
		"raw",
		encoder.encode(secret),
		{ name: "HMAC", hash: "SHA-256" },
		false,
		["sign"],
	);
	return hex(await crypto.subtle.sign("HMAC", key, encoder.encode(message)));
}

/** Equal without saying where they differ: both are hashed to one length first. */
export async function sameSecret(provided: string, expected: string): Promise<boolean> {
	const [a, b] = await Promise.all([
		crypto.subtle.digest("SHA-256", encoder.encode(provided)),
		crypto.subtle.digest("SHA-256", encoder.encode(expected)),
	]);
	return crypto.subtle.timingSafeEqual(a, b);
}

/** Discord's signature over an interaction: Ed25519, key and signature in hex. */
export async function verifyEd25519(
	publicKeyHex: string,
	signatureHex: string,
	message: Uint8Array,
): Promise<boolean> {
	const publicKey = fromHex(publicKeyHex);
	const signature = fromHex(signatureHex);
	if (!publicKey || publicKey.length !== 32 || !signature || signature.length !== 64) return false;
	try {
		const key = await crypto.subtle.importKey("raw", publicKey, { name: "Ed25519" }, false, ["verify"]);
		return await crypto.subtle.verify({ name: "Ed25519" }, key, signature, message);
	} catch {
		return false;
	}
}

export function concat(...parts: Uint8Array[]): Uint8Array {
	const total = parts.reduce((sum, part) => sum + part.byteLength, 0);
	const joined = new Uint8Array(total);
	let offset = 0;
	for (const part of parts) {
		joined.set(part, offset);
		offset += part.byteLength;
	}
	return joined;
}
