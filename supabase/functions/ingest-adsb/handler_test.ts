import assert from 'node:assert/strict';
import { RateLimitedError } from '../_shared/opensky.ts';
import { createHandler } from './handler.ts';

const SECRET = 'x';
const box = { min_lat: 46, min_lon: -124, max_lat: 49, max_lon: -120.5, area_sq_deg: 10.5 };
const sv = (icao: string, t = 1793818370) => [icao, 'ABC123', 'US', t, t, -122.3, 47.5, 9000, false, 230, 10, 0, null, 9100, null, false, 0];

function setup(states: (b: unknown) => Promise<{ states: unknown[]; creditsRemaining: number | null }>, boxes = [box]) {
	const calls: { fn: string; args?: Record<string, unknown> }[] = [];
	const handler = createHandler({
		secret: SECRET,
		log: () => {},
		opensky: { states: states as never, authenticated: true },
		rpc: async <T>(fn: string, args?: Record<string, unknown>) => {
			calls.push({ fn, args });
			if (fn === 'adsb_fetch_areas') return { data: boxes as T, error: null };
			if (fn === 'ingest_track_points') {
				const n = (args!.points as unknown[]).length;
				return { data: { inserted: n, duplicate: 0, invalid: 0 } as T, error: null };
			}
			return { data: { inserted: 1, updated: 0, removed: 0, too_low: 0 } as T, error: null };
		}
	});
	const post = (s = SECRET) => handler(new Request('http://x/', { method: 'POST', headers: { 'x-ingest-secret': s } }));
	return { post, calls };
}

Deno.test('auth required', async () => {
	const { post, calls } = setup(async () => ({ states: [], creditsRemaining: null }));
	assert.equal((await post('nope')).status, 401);
	assert.equal(calls.length, 0);
});

Deno.test('stores positions, dedupes boxes, recomputes predictions', async () => {
	const { post, calls } = setup(async () => ({ states: [sv('a00001'), sv('a00002'), ['bad']], creditsRemaining: 3900 }), [
		box,
		{ ...box, min_lat: 47 }
	]);
	const res = await post();
	assert.equal(res.status, 200);
	const body = await res.json();
	assert.equal(body.areas, 2);
	assert.equal(body.credits_used, 2);
	assert.equal(body.credits_remaining, 3900);
	assert.equal(body.states, 6);
	assert.equal(body.positions, 2);
	assert.deepEqual(body.predictions, { inserted: 1, updated: 0, removed: 0, too_low: 0 });
	assert.deepEqual(calls.map((c) => c.fn), ['adsb_fetch_areas', 'ingest_track_points', 'compute_live_predictions']);
	const pts = calls[1].args!.points as { icao24: string; altitude_ft: number }[];
	assert.deepEqual(pts.map((p) => p.icao24), ['a00001', 'a00002']);
	assert.equal(pts[0].altitude_ft, 29528);
});

Deno.test('rate limit stops polling but still recomputes', async () => {
	let n = 0;
	const { post, calls } = setup(async () => {
		if (++n === 1) return { states: [sv('a00001')], creditsRemaining: 1 };
		throw new RateLimitedError(1800);
	}, [box, { ...box, min_lat: 47 }, { ...box, min_lat: 48 }]);
	const res = await post();
	const body = await res.json();
	assert.equal(res.status, 200); // one area succeeded
	assert.equal(n, 2); // third box never requested
	assert.equal(body.rate_limited, true);
	assert.equal(body.retry_after_s, 1800);
	assert.equal(body.credits_used, 1);
	assert.ok(calls.some((c) => c.fn === 'compute_live_predictions'));
});

Deno.test('every request failing: 502, predictions still cleaned up', async () => {
	const { post, calls } = setup(async () => {
		throw new Error('OpenSky 503');
	});
	const res = await post();
	assert.equal(res.status, 502);
	assert.ok(calls.some((c) => c.fn === 'compute_live_predictions'));
	assert.equal(calls.some((c) => c.fn === 'ingest_track_points'), false);
});

Deno.test('no spots: no OpenSky requests', async () => {
	let n = 0;
	const { post } = setup(async () => {
		n++;
		return { states: [], creditsRemaining: null };
	}, []);
	const body = await (await post()).json();
	assert.equal(n, 0);
	assert.equal(body.areas, 0);
});
