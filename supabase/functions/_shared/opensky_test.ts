import assert from 'node:assert/strict';
import { OPENSKY_TOKEN_URL, OpenSkyClient, RateLimitedError, parseStateVector } from './opensky.ts';

// One state vector as returned by /states/all?extended=1
const sv = ['a1b2c3', 'ASA123  ', 'United States', 1793818370, 1793818371, -122.28, 47.52, 10058.4, false,
	231.5, 359.96, -5.2, null, 10241.3, '4521', false, 0, 4];

Deno.test('parseStateVector: units and cleanup', () => {
	assert.deepEqual(parseStateVector(sv), {
		icao24: 'a1b2c3',
		observed_at: '2026-11-04T18:52:50.000Z',
		callsign: 'ASA123',
		lat: 47.52,
		lon: -122.28,
		altitude_ft: 33000,
		geo_altitude_ft: 33600,
		on_ground: false,
		ground_speed_kt: 450,
		heading_deg: 0, // 359.96 rounds to 360.0 -> 0
		vertical_rate_fpm: -1024,
		squawk: '4521',
		source: 'opensky'
	});
});

Deno.test('parseStateVector: rejects unusable vectors', () => {
	assert.equal(parseStateVector([...sv.slice(0, 5), null, null, ...sv.slice(7)]), null); // no position
	assert.equal(parseStateVector(['zzzzzz', ...sv.slice(1)]), null);
	assert.equal(parseStateVector('nope'), null);
	const noTimePos = [...sv];
	noTimePos[3] = null;
	assert.equal(parseStateVector(noTimePos)?.observed_at, '2026-11-04T18:52:51.000Z'); // falls back to last_contact
	const mlat = [...sv];
	mlat[16] = 2;
	mlat[1] = '        ';
	assert.equal(parseStateVector(mlat)?.source, 'opensky-mlat');
	assert.equal(parseStateVector(mlat)?.callsign, null);
});

const box = { min_lat: 46, min_lon: -124, max_lat: 49, max_lon: -120.5 };

Deno.test('statesUrl', () => {
	assert.equal(
		OpenSkyClient.statesUrl(box),
		'https://opensky-network.org/api/states/all?lamin=46&lomin=-124&lamax=49&lomax=-120.5&extended=1'
	);
});

function fakeFetch(handler: (url: string, init: RequestInit) => Response) {
	const calls: { url: string; init: RequestInit }[] = [];
	const f = (async (url: string, init: RequestInit = {}) => {
		calls.push({ url, init });
		return handler(url, init);
	}) as typeof fetch;
	return { f, calls };
}

Deno.test('client credentials: token fetched once and reused', async () => {
	let tokens = 0;
	const { f, calls } = fakeFetch((url) => {
		if (url === OPENSKY_TOKEN_URL) return Response.json({ access_token: `tok${++tokens}`, expires_in: 1800 });
		return Response.json({ time: 1, states: [sv] }, { headers: { 'X-Rate-Limit-Remaining': '3990' } });
	});
	const c = new OpenSkyClient({ fetch: f, clientId: 'id', clientSecret: 'sec', userAgent: 'ua' });
	const r1 = await c.states(box);
	await c.states(box);
	assert.equal(tokens, 1);
	assert.equal(r1.states.length, 1);
	assert.equal(r1.creditsRemaining, 3990);
	const tokenCall = calls[0];
	assert.equal(String(tokenCall.init.body), 'grant_type=client_credentials&client_id=id&client_secret=sec');
	assert.equal(new Headers(calls[1].init.headers).get('authorization'), 'Bearer tok1');
});

Deno.test('401 refreshes the token once', async () => {
	let tokens = 0;
	let stateCalls = 0;
	const { f } = fakeFetch((url) => {
		if (url === OPENSKY_TOKEN_URL) return Response.json({ access_token: `tok${++tokens}`, expires_in: 1800 });
		return ++stateCalls === 1 ? new Response('', { status: 401 }) : Response.json({ states: null });
	});
	const c = new OpenSkyClient({ fetch: f, clientId: 'id', clientSecret: 'sec', userAgent: 'ua' });
	const r = await c.states(box);
	assert.equal(tokens, 2);
	assert.deepEqual(r.states, []); // "states": null means no aircraft
});

Deno.test('anonymous: no token request, no auth header', async () => {
	const { f, calls } = fakeFetch(() => Response.json({ states: [] }));
	const c = new OpenSkyClient({ fetch: f, userAgent: 'ua' });
	assert.equal(c.authenticated, false);
	await c.states(box);
	assert.equal(calls.length, 1);
	assert.equal(new Headers(calls[0].init.headers).get('authorization'), null);
});

Deno.test('429 raises RateLimitedError with retry time', async () => {
	const { f } = fakeFetch(
		() => new Response('', { status: 429, headers: { 'X-Rate-Limit-Retry-After-Seconds': '3600' } })
	);
	const c = new OpenSkyClient({ fetch: f, userAgent: 'ua' });
	await assert.rejects(c.states(box), (e: unknown) => e instanceof RateLimitedError && e.retryAfterS === 3600);
});
