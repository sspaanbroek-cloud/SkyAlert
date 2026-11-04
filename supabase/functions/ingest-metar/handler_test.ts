import assert from 'node:assert/strict';
import { createHandler, timingSafeEqual } from './handler.ts';

const SECRET = 's3cret-value';
const box = { min_lat: 46.33, min_lon: -123.99, max_lat: 48.67, max_lon: -121.01 };
const metar = (icao: string, obsTime: number, raw: string) => ({
	icaoId: icao, obsTime, rawOb: raw, lat: 47.5, lon: -122.3, elev: 10, visib: '10+', wdir: 180, wspd: 5, fltCat: 'VFR'
});

function setup(opts: { awc?: (url: string, init?: RequestInit) => Response; boxes?: unknown[] } = {}) {
	const calls: { fn: string; args?: Record<string, unknown> }[] = [];
	const urls: string[] = [];
	const headers: Headers[] = [];
	const handler = createHandler({
		secret: SECRET,
		userAgent: 'SkyAlert/test',
		log: () => {},
		sleep: async () => {},
		fetch: (async (url: string, init?: RequestInit) => {
			urls.push(url);
			headers.push(new Headers(init?.headers));
			return opts.awc ? opts.awc(url, init) : Response.json([]);
		}) as typeof fetch,
		rpc: async <T>(fn: string, args?: Record<string, unknown>) => {
			calls.push({ fn, args });
			if (fn === 'metar_fetch_areas') return { data: (opts.boxes ?? [box]) as T, error: null };
			if (fn === 'ingest_tafs') return { data: { stored: (args!.tafs as unknown[]).length, unchanged: 0, rejected: [] } as T, error: null };
			if (fn === 'refresh_visibility_assessments') return { data: { clear: 0, partial: 1, hidden: 0, unknown: 0 } as T, error: null };
			const n = (args?.reports as unknown[]).length;
			return { data: { stored: n, unchanged: 0, rejected: [] } as T, error: null };
		}
	});
	const post = (secret = SECRET) =>
		handler(new Request('http://x/ingest-metar', { method: 'POST', headers: { 'x-ingest-secret': secret } }));
	return { handler, post, calls, urls, headers };
}

Deno.test('rejects missing or wrong secret, and non-POST', async () => {
	const { handler, post, calls } = setup();
	assert.equal((await post('wrong')).status, 401);
	assert.equal((await handler(new Request('http://x/', { method: 'POST' }))).status, 401);
	assert.equal((await handler(new Request('http://x/'))).status, 405);
	assert.equal(calls.length, 0);
});

Deno.test('fetches each area, dedupes overlaps, stores, reports', async () => {
	const a = metar('KBFI', 1793818380, 'KBFI 041853Z 18005KT 10SM BKN060 12/08 A3001');
	const b = metar('KRNT', 1793818380, 'KRNT 041853Z AUTO 00000KT 10SM CLR 11/07 A3002');
	const bad = { icaoId: 'KXXX', rawOb: 'KXXX 041853Z', lat: 1, lon: 1 }; // no elevation
	const { post, calls, urls, headers } = setup({
		boxes: [box, { ...box, min_lat: 47 }],
		awc: () => Response.json([a, b, bad]) // both boxes return the same stations
	});
	const res = await post();
	assert.equal(res.status, 200);
	const body = await res.json();
	assert.equal(body.areas, 2);
	assert.equal(body.fetched, 6);
	assert.equal(body.parsed, 2);
	assert.equal(body.stored, 2);
	assert.equal(body.parse_rejected.length, 2);
	assert.equal(urls[0], 'https://aviationweather.gov/api/data/metar?bbox=46.33,-123.99,48.67,-121.01&format=json&hours=2');
	assert.equal(headers[0].get('user-agent'), 'SkyAlert/test');
	const ingest = calls.find((c) => c.fn === 'ingest_metars')!;
	const reports = ingest.args!.reports as { station: { icao: string }; layers: unknown[] }[];
	assert.deepEqual(reports.map((r) => r.station.icao), ['KBFI', 'KRNT']);
	assert.equal(reports[0].layers.length, 1);
	assert.equal(calls.at(-1)!.fn, 'refresh_visibility_assessments');
	assert.deepEqual(body.visibility, { clear: 0, partial: 1, hidden: 0, unknown: 0 });
});

Deno.test('no spots: nothing fetched', async () => {
	const { post, urls } = setup({ boxes: [] });
	const body = await (await post()).json();
	assert.equal(body.areas, 0);
	assert.equal(urls.length, 0);
});

Deno.test('AWC 204 is an empty result; 429 is retried once', async () => {
	let n = 0;
	const { post } = setup({
		awc: (url) =>
			!url.includes('/metar?')
				? new Response(null, { status: 204 })
				: ++n === 1
					? new Response(null, { status: 429, headers: { 'Retry-After': '1' } })
					: new Response(null, { status: 204 })
	});
	const body = await (await post()).json();
	assert.equal(n, 2);
	assert.equal(body.fetched, 0);
	assert.deepEqual(body.fetch_errors, []);
});

Deno.test('all AWC requests failing returns 502 and stores nothing', async () => {
	const { post, calls } = setup({ awc: () => new Response('down', { status: 503, statusText: 'Service Unavailable' }) });
	const res = await post();
	assert.equal(res.status, 502);
	assert.match((await res.json()).fetch_errors[0], /AWC 503/);
	assert.equal(calls.some((c) => c.fn === 'ingest_metars'), false);
});

Deno.test('timingSafeEqual', () => {
	assert.equal(timingSafeEqual('abc', 'abc'), true);
	assert.equal(timingSafeEqual('abc', 'abd'), false);
	assert.equal(timingSafeEqual('abc', 'abcd'), false);
	assert.equal(timingSafeEqual('', ''), true);
});

Deno.test('TAFs fetched for the same areas and stored; TAF failure does not block METARs', async () => {
	const taf = {
		icaoId: 'KSEA', issueTime: '2026-11-04T14:40:00Z', validTimeFrom: 1793804400, validTimeTo: 1793912400,
		rawTAF: 'TAF KSEA ...', lat: 47.44, lon: -122.31, elev: 132,
		fcsts: [{ timeFrom: 1793804400, fcstChange: null, visib: '6+', clouds: [{ cover: 'BKN', base: 6000 }] }]
	};
	const ok = setup({
		awc: (url) => (url.includes('/taf?') ? Response.json([taf]) : Response.json([metar('KBFI', 1793818380, 'KBFI 041853Z 10SM BKN060 A3001')]))
	});
	const body = await (await ok.post()).json();
	assert.ok(ok.urls.some((u) => u.startsWith('https://aviationweather.gov/api/data/taf?bbox=')));
	assert.equal(body.stored, 1);
	assert.equal(body.tafs.parsed, 1);
	assert.deepEqual(body.tafs.result, { stored: 1, unchanged: 0, rejected: [] });

	const broken = setup({
		awc: (url) => (url.includes('/taf?') ? new Response('', { status: 500 }) : Response.json([metar('KBFI', 1793818380, 'KBFI 041853Z 10SM CLR A3001')]))
	});
	const res = await broken.post();
	const b2 = await res.json();
	assert.equal(res.status, 200);
	assert.equal(b2.stored, 1);
	assert.match(b2.tafs.errors[0], /AWC 500/);
});
