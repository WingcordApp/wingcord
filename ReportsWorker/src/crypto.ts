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

export async function hmacHex(secret: string, message: string | Uint8Array): Promise<string> {
	const key = await crypto.subtle.importKey(
		"raw",
		encoder.encode(secret),
		{ name: "HMAC", hash: "SHA-256" },
		false,
		["sign"],
	);
	const bytes = typeof message === "string" ? encoder.encode(message) : message;
	return hex(await crypto.subtle.sign("HMAC", key, bytes));
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

/** Standard base 64, whitespace ignored. */
export function fromBase64(text: string): Uint8Array {
	return Uint8Array.from(atob(text.replace(/\s+/g, "")), (character) => character.charCodeAt(0));
}

// MARK: The GitHub App's key

/**
 * A private key in PEM as Web Crypto takes it (PKCS #8). GitHub hands an
 * App's key out as PKCS #1 (`BEGIN RSA PRIVATE KEY`), which Web Crypto
 * cannot import, so that is wrapped in PKCS #8's envelope here; a key
 * already in PKCS #8 passes through. A secret pasted with its line breaks
 * written as `\n` is read too.
 */
export function pkcs8FromPem(pem: string): Uint8Array {
	const text = pem.replace(/\\n/g, "\n");
	const match = /-----BEGIN (RSA )?PRIVATE KEY-----([^-]+)-----END (RSA )?PRIVATE KEY-----/.exec(text);
	if (!match) throw new Error("the GitHub App's key is not a PEM private key");
	const der = fromBase64(match[2]!);
	return match[1] ? wrapPkcs1(der) : der;
}

/** PrivateKeyInfo ::= SEQUENCE { version 0, AlgorithmIdentifier { rsaEncryption, NULL }, OCTET STRING { the PKCS #1 key } } */
function wrapPkcs1(pkcs1: Uint8Array): Uint8Array {
	const version = Uint8Array.of(0x02, 0x01, 0x00);
	// SEQUENCE { OID 1.2.840.113549.1.1.1, NULL }
	const algorithm = Uint8Array.of(0x30, 0x0d, 0x06, 0x09, 0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x01, 0x01, 0x05, 0x00);
	return derElement(0x30, concat(version, algorithm, derElement(0x04, pkcs1)));
}

function derElement(tag: number, content: Uint8Array): Uint8Array {
	const length = content.byteLength;
	let header: Uint8Array;
	if (length < 0x80) {
		header = Uint8Array.of(tag, length);
	} else {
		const bytes: number[] = [];
		for (let rest = length; rest > 0; rest = Math.floor(rest / 256)) bytes.unshift(rest % 256);
		header = Uint8Array.of(tag, 0x80 | bytes.length, ...bytes);
	}
	return concat(header, content);
}

/** A JSON Web Token signed with RS256, as GitHub asks of an App. */
export async function signJwt(pem: string, claims: Record<string, unknown>): Promise<string> {
	const key = await crypto.subtle.importKey(
		"pkcs8",
		pkcs8FromPem(pem),
		{ name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" },
		false,
		["sign"],
	);
	const head = base64url(encoder.encode(JSON.stringify({ alg: "RS256", typ: "JWT" })));
	const body = base64url(encoder.encode(JSON.stringify(claims)));
	const signature = await crypto.subtle.sign("RSASSA-PKCS1-v1_5", key, encoder.encode(`${head}.${body}`));
	return `${head}.${body}.${base64url(new Uint8Array(signature))}`;
}
