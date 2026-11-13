// The answers an interaction can get (Discord's interaction callback types).
// Discord wants one within three seconds; slow work answers "deferred" and
// finishes in `ctx.waitUntil`, telling its outcome afterwards.

import { EPHEMERAL, SUPPRESS_EMBEDS } from "./discord";
import { json } from "./http";
import type { MessageBody } from "./inbox";
import type { Modal } from "./modal";

const CHANNEL_MESSAGE = 4;
const DEFERRED_CHANNEL_MESSAGE = 5;
const DEFERRED_UPDATE_MESSAGE = 6;
const UPDATE_MESSAGE = 7;
const MODAL = 9;

/** A reply only the presser sees. */
export function reply(content: string): Response {
	return json({ type: CHANNEL_MESSAGE, data: { content, flags: EPHEMERAL, allowed_mentions: { parse: [] } } });
}

/** The words a deferred press's reply is rewritten with: links to GitHub don't unfold into previews. */
export function outcome(content: string) {
	return { content, flags: SUPPRESS_EMBEDS, allowed_mentions: { parse: [] as [] } };
}

/** "Wingcord is thinking…", seen by the presser only, rewritten when the work is done. */
export function thinking(): Response {
	return json({ type: DEFERRED_CHANNEL_MESSAGE, data: { flags: EPHEMERAL } });
}

/** Nothing to see yet: the message pressed on is redrawn when the work is done. */
export function deferUpdate(): Response {
	return json({ type: DEFERRED_UPDATE_MESSAGE });
}

export function updateMessage(message: MessageBody): Response {
	return json({ type: UPDATE_MESSAGE, data: message });
}

export function openModal(modal: Modal): Response {
	return json({ type: MODAL, data: modal });
}

/** Where a deferred press's outcome is told. */
export interface ReplyTarget {
	applicationId: string;
	token: string;
}
