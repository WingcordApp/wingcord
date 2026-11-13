// The two schedules: every 15 minutes, post what the inbox has not had;
// every day, the 90-day rule.

import { CRONS, nowSeconds } from "./config";
import { postInbox } from "./discord";
import { objectKeys } from "./files";
import { log } from "./http";
import { expire, unposted } from "./store";

/** Bounded so one run stays far inside the free plan's limits. */
const POSTS_PER_RUN = 10;
const EXPIRIES_PER_RUN = 100;

export async function handleScheduled(controller: ScheduledController, env: Env): Promise<void> {
	const now = nowSeconds();
	if (controller.cron === CRONS.daily) {
		const expired = await expire(env.DB, now, EXPIRIES_PER_RUN);
		const ids = [...expired.removed, ...expired.stripped];
		// The lifecycle rule would delete these too; this keeps the bucket and
		// the index agreeing on the day.
		if (ids.length) await env.BUCKET.delete(ids.flatMap(objectKeys));
		log("retention.ran", { removed: expired.removed.length, stripped: expired.stripped.length });
		return;
	}
	const ids = await unposted(env.DB, now, POSTS_PER_RUN);
	for (const id of ids) await postInbox(env, id);
	if (ids.length) log("inbox.caught_up", { count: ids.length });
}
