import assert from 'node:assert/strict';
import { cloudUrl, fetchModelCloud, parseCloudResponse } from './openmeteo.ts';

const a = { cell_key: '47.5,-122.3', lat: 47.5, lon: -122.3 };
const b = { cell_key: '47.9,-122.3', lat: 47.9, lon: -122.3 };
const resp = (high: (number | null)[]) => ({
	latitude: 47.5, longitude: -122.3,
	hourly: { time: [1793818800, 1793822400, 1793826000], cloud_cover_low: [0, 5, null], cloud_cover_mid: [40, 30.6, null],
	          cloud_cover_high: high }
});

Deno.test('cloudUrl: multi-location, unixtime, free vs customer host', () => {
	const u = new URL(cloudUrl([a, b]));
	assert.equal(u.origin + u.pathname, 'https://api.open-meteo.com/v1/forecast');
	assert.equal(u.searchParams.get('latitude'), '47.5,47.9');
	assert.equal(u.searchParams.get('hourly'), 'cloud_cover_low,cloud_cover_mid,cloud_cover_high');
	assert.equal(u.searchParams.get('timeformat'), 'unixtime');
	const paid = new URL(cloudUrl([a], { apiKey: 'k' }));
	assert.equal(paid.host, 'customer-api.open-meteo.com');
	assert.equal(paid.searchParams.get('apikey'), 'k');
});

Deno.test('parseCloudResponse: rounds, clamps, skips empty hours', () => {
	const rows = parseCloudResponse(a, resp([85, 101, null]));
	assert.equal(rows.length, 2);
	assert.deepEqual(rows[0], { ...a, valid_at: '2026-11-04T19:00:00.000Z', low: 0, mid: 40, high: 85, model: 'best_match' });
	assert.equal(rows[1].mid, 31);
	assert.equal(rows[1].high, 100);
	assert.deepEqual(parseCloudResponse(a, { error: true }), []);
});

Deno.test('fetchModelCloud: one request for many points, array answer in order', async () => {
	const urls: string[] = [];
	const f = (async (url: string) => {
		urls.push(url);
		return Response.json([resp([10, 20, 30]), resp([90, 90, 90])]);
	}) as typeof fetch;
	const rows = await fetchModelCloud([a, b], { fetch: f, userAgent: 'ua' });
	assert.equal(urls.length, 1);
	assert.equal(rows.filter((r) => r.cell_key === b.cell_key)[0].high, 90);
});

Deno.test('fetchModelCloud: single point gets an object; errors surface', async () => {
	const one = (async () => Response.json(resp([50, 50, 50]))) as unknown as typeof fetch;
	assert.equal((await fetchModelCloud([a], { fetch: one, userAgent: 'ua' })).length, 3);
	const bad = (async () => new Response('{"reason":"Daily limit exceeded"}', { status: 429 })) as unknown as typeof fetch;
	await assert.rejects(fetchModelCloud([a], { fetch: bad, userAgent: 'ua' }), /Open-Meteo 429: .*Daily limit/);
});
