import assert from 'node:assert/strict';
import { createHandler } from './handler.ts';

const pts = [{ cell_key: '47.5,-122.3', lat: 47.5, lon: -122.3 }];
const om = { hourly: { time: [1793818800], cloud_cover_low: [0], cloud_cover_mid: [10], cloud_cover_high: [80] } };

function setup(fetchImpl: () => Response, points = pts) {
	const calls: { fn: string; args?: Record<string, unknown> }[] = [];
	const h = createHandler({
		secret: 's', userAgent: 'ua', log: () => {},
		fetch: (async () => fetchImpl()) as unknown as typeof fetch,
		rpc: async <T>(fn: string, args?: Record<string, unknown>) => {
			calls.push({ fn, args });
			if (fn === 'model_cloud_points') return { data: points as T, error: null };
			return { data: { ok: true } as T, error: null };
		}
	});
	const post = (s = 's') => h(new Request('http://x/', { method: 'POST', headers: { 'x-ingest-secret': s } }));
	return { post, calls };
}

Deno.test('auth required', async () => {
	assert.equal((await setup(() => Response.json(om)).post('no')).status, 401);
});

Deno.test('fetches, stores, re-rates', async () => {
	const { post, calls } = setup(() => Response.json(om));
	const res = await post();
	assert.equal(res.status, 200);
	assert.deepEqual(calls.map((c) => c.fn), ['model_cloud_points', 'ingest_model_cloud', 'refresh_visibility_assessments']);
	const rows = calls[1].args!.points as { high: number; cell_key: string }[];
	assert.equal(rows[0].high, 80);
	assert.equal(rows[0].cell_key, '47.5,-122.3');
});

Deno.test('Open-Meteo down: 502, nothing stored', async () => {
	const { post, calls } = setup(() => new Response('oops', { status: 503 }));
	assert.equal((await post()).status, 502);
	assert.equal(calls.some((c) => c.fn === 'ingest_model_cloud'), false);
});

Deno.test('no spots: no request', async () => {
	let n = 0;
	const { post } = setup(() => {
		n++;
		return Response.json(om);
	}, []);
	assert.equal((await (await post()).json()).points, 0);
	assert.equal(n, 0);
});
