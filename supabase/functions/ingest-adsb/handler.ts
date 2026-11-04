// Request handler for ingest-adsb: poll OpenSky around every spot, store the
// positions, recompute live passes. Dependencies are injected for testing.
import type { Box } from '../_shared/awc.ts';
import { OpenSkyClient, RateLimitedError, parseStateVector, type TrackRecord } from '../_shared/opensky.ts';
import { type RpcResult, timingSafeEqual } from '../ingest-metar/handler.ts';

export interface Deps {
	rpc: <T>(fn: string, args?: Record<string, unknown>) => Promise<RpcResult<T>>;
	opensky: Pick<OpenSkyClient, 'states' | 'authenticated'>;
	secret: string | undefined;
	log?: (msg: string, extra?: unknown) => void;
}

const BATCH = 1000;

const json = (status: number, body: unknown) =>
	new Response(JSON.stringify(body), { status, headers: { 'Content-Type': 'application/json' } });

export function createHandler(deps: Deps) {
	const log = deps.log ?? ((msg: string, extra?: unknown) => console.log(msg, extra ?? ''));

	return async function handle(req: Request): Promise<Response> {
		if (req.method !== 'POST') return json(405, { error: 'POST only' });
		if (!deps.secret) return json(500, { error: 'INGEST_SECRET is not configured' });
		if (!timingSafeEqual(req.headers.get('x-ingest-secret') ?? '', deps.secret)) {
			return json(401, { error: 'unauthorized' });
		}

		const areas = await deps.rpc<(Box & { area_sq_deg: number })[]>('adsb_fetch_areas');
		if (areas.error) return json(500, { error: `adsb_fetch_areas: ${areas.error.message}` });
		const boxes = areas.data ?? [];

		const fetchErrors: string[] = [];
		let rateLimited: number | null | undefined;
		let creditsRemaining: number | null = null;
		const byKey = new Map<string, TrackRecord>();
		let fetched = 0;
		let okRequests = 0;

		for (const box of boxes) {
			try {
				const res = await deps.opensky.states(box);
				okRequests++;
				fetched += res.states.length;
				creditsRemaining = res.creditsRemaining ?? creditsRemaining;
				for (const sv of res.states) {
					const r = parseStateVector(sv);
					if (r) byKey.set(`${r.icao24}|${r.observed_at}`, r);
				}
			} catch (e) {
				if (e instanceof RateLimitedError) {
					rateLimited = e.retryAfterS;
					fetchErrors.push(e.message);
					break; // every further request would be refused too
				}
				fetchErrors.push(`${JSON.stringify(box)}: ${(e as Error).message}`);
			}
		}

		// Store what we got, then always recompute: even with no new data,
		// predictions for aircraft that went out of range must be cleaned up.
		const records = [...byKey.values()];
		const stored = { inserted: 0, duplicate: 0, invalid: 0 };
		for (let i = 0; i < records.length; i += BATCH) {
			const res = await deps.rpc<typeof stored>('ingest_track_points', { points: records.slice(i, i + BATCH) });
			if (res.error || !res.data) return json(500, { error: `ingest_track_points: ${res.error?.message ?? 'no result'}` });
			stored.inserted += res.data.inserted;
			stored.duplicate += res.data.duplicate;
			stored.invalid += res.data.invalid;
		}

		let predictions: unknown = null;
		if (boxes.length > 0) {
			const res = await deps.rpc('compute_live_predictions');
			if (res.error) return json(500, { error: `compute_live_predictions: ${res.error.message}`, stored });
			predictions = res.data;
		}

		const summary = {
			areas: boxes.length,
			authenticated: deps.opensky.authenticated,
			credits_used: okRequests, // each box is <= 25 sq deg: 1 credit
			credits_remaining: creditsRemaining,
			states: fetched,
			positions: records.length,
			...stored,
			predictions,
			rate_limited: rateLimited !== undefined,
			retry_after_s: rateLimited ?? null,
			fetch_errors: fetchErrors
		};
		if (fetchErrors.length) log('ingest-adsb: errors', summary);
		const allFailed = boxes.length > 0 && fetchErrors.length >= boxes.length;
		return json(allFailed ? (rateLimited !== undefined ? 429 : 502) : 200, summary);
	};
}
