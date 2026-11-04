// OpenSky Network REST client (https://openskynetwork.github.io/opensky-api/rest.html).
//
// Auth: OAuth2 client credentials (create an API client in your OpenSky
// account). Without credentials it falls back to anonymous access, which has
// a much smaller daily credit allowance.
// Cost: /states/all with a bounding box <= 25 sq deg costs 1 credit.

import type { Box } from './awc.ts';

export const OPENSKY_STATES_URL = 'https://opensky-network.org/api/states/all';
export const OPENSKY_TOKEN_URL =
	'https://auth.opensky-network.org/auth/realms/opensky-network/protocol/openid-connect/token';

const M_TO_FT = 3.28084;
const MS_TO_KT = 1.943844;
const MS_TO_FPM = 196.8504;

/** Shape sent to public.ingest_track_points(). Keep in sync with that function. */
export interface TrackRecord {
	icao24: string;
	observed_at: string;
	callsign: string | null;
	lat: number;
	lon: number;
	altitude_ft: number | null;
	geo_altitude_ft: number | null;
	on_ground: boolean;
	ground_speed_kt: number | null;
	heading_deg: number | null;
	vertical_rate_fpm: number | null;
	squawk: string | null;
	source: string;
}

const num = (v: unknown): number | null => (typeof v === 'number' && Number.isFinite(v) ? v : null);
const round = (v: number | null, dp = 0) => (v === null ? null : Math.round(v * 10 ** dp) / 10 ** dp);

/**
 * One state vector (array form) -> track record, or null when it has no
 * usable position. Index meanings from the OpenSky docs:
 * 0 icao24, 1 callsign, 3 time_position, 4 last_contact, 5 lon, 6 lat,
 * 7 baro_altitude m, 8 on_ground, 9 velocity m/s, 10 true_track deg,
 * 11 vertical_rate m/s, 13 geo_altitude m, 14 squawk, 16 position_source.
 */
export function parseStateVector(sv: unknown): TrackRecord | null {
	if (!Array.isArray(sv)) return null;
	const icao24 = typeof sv[0] === 'string' ? sv[0].trim().toLowerCase() : '';
	if (!/^[0-9a-f]{6}$/.test(icao24)) return null;
	const lon = num(sv[5]);
	const lat = num(sv[6]);
	if (lat === null || lon === null) return null;
	const t = num(sv[3]) ?? num(sv[4]);
	if (t === null) return null;

	let heading = round(num(sv[10]), 1);
	if (heading !== null) heading = ((heading % 360) + 360) % 360;
	const baro = num(sv[7]);
	const geo = num(sv[13]);
	const vel = num(sv[9]);
	const vr = num(sv[11]);
	const callsign = typeof sv[1] === 'string' && sv[1].trim() ? sv[1].trim() : null;

	return {
		icao24,
		observed_at: new Date(t * 1000).toISOString(),
		callsign,
		lat,
		lon,
		altitude_ft: baro === null ? null : Math.round(baro * M_TO_FT),
		geo_altitude_ft: geo === null ? null : Math.round(geo * M_TO_FT),
		on_ground: sv[8] === true,
		ground_speed_kt: vel === null ? null : round(vel * MS_TO_KT, 1),
		heading_deg: heading,
		vertical_rate_fpm: vr === null ? null : Math.round(vr * MS_TO_FPM),
		squawk: typeof sv[14] === 'string' && sv[14] ? sv[14] : null,
		source: sv[16] === 2 ? 'opensky-mlat' : 'opensky'
	};
}

export interface OpenSkyOptions {
	fetch?: typeof fetch;
	clientId?: string;
	clientSecret?: string;
	userAgent: string;
	timeoutMs?: number;
	now?: () => number;
}

export class RateLimitedError extends Error {
	constructor(public retryAfterS: number | null) {
		super(`OpenSky rate limit reached${retryAfterS ? `; retry in ${retryAfterS}s` : ''}`);
	}
}

export interface StatesResult {
	states: unknown[];
	/** X-Rate-Limit-Remaining: credits left today, when OpenSky reports it. */
	creditsRemaining: number | null;
}

export class OpenSkyClient {
	#token: { value: string; expiresAt: number } | null = null;
	#fetch: typeof fetch;
	#now: () => number;

	constructor(private opts: OpenSkyOptions) {
		this.#fetch = opts.fetch ?? fetch;
		this.#now = opts.now ?? Date.now;
	}

	get authenticated() {
		return Boolean(this.opts.clientId && this.opts.clientSecret);
	}

	async #getToken(force = false): Promise<string | null> {
		if (!this.authenticated) return null;
		if (!force && this.#token && this.#token.expiresAt > this.#now() + 60_000) return this.#token.value;
		const res = await this.#fetch(OPENSKY_TOKEN_URL, {
			method: 'POST',
			headers: { 'Content-Type': 'application/x-www-form-urlencoded', 'User-Agent': this.opts.userAgent },
			body: new URLSearchParams({
				grant_type: 'client_credentials',
				client_id: this.opts.clientId!,
				client_secret: this.opts.clientSecret!
			}),
			signal: AbortSignal.timeout(this.opts.timeoutMs ?? 15000)
		});
		if (!res.ok) {
			await res.body?.cancel();
			throw new Error(`OpenSky token request failed: ${res.status}`);
		}
		const body = (await res.json()) as { access_token?: string; expires_in?: number };
		if (!body.access_token) throw new Error('OpenSky token response had no access_token');
		this.#token = { value: body.access_token, expiresAt: this.#now() + (body.expires_in ?? 1800) * 1000 };
		return this.#token.value;
	}

	static statesUrl(box: Box): string {
		const r = (n: number) => Math.round(n * 1000) / 1000;
		const q = new URLSearchParams({
			lamin: String(r(box.min_lat)),
			lomin: String(r(box.min_lon)),
			lamax: String(r(box.max_lat)),
			lomax: String(r(box.max_lon)),
			extended: '1'
		});
		return `${OPENSKY_STATES_URL}?${q}`;
	}

	async states(box: Box): Promise<StatesResult> {
		for (let attempt = 0; attempt < 2; attempt++) {
			const token = await this.#getToken(attempt > 0);
			const headers: Record<string, string> = { 'User-Agent': this.opts.userAgent, Accept: 'application/json' };
			if (token) headers.Authorization = `Bearer ${token}`;
			const res = await this.#fetch(OpenSkyClient.statesUrl(box), {
				headers,
				signal: AbortSignal.timeout(this.opts.timeoutMs ?? 20000)
			});
			const remaining = res.headers.get('X-Rate-Limit-Remaining');
			if (res.status === 401 && token && attempt === 0) {
				await res.body?.cancel();
				continue; // token expired or revoked: get a fresh one once
			}
			if (res.status === 429) {
				await res.body?.cancel();
				const retry = Number(res.headers.get('X-Rate-Limit-Retry-After-Seconds'));
				throw new RateLimitedError(Number.isFinite(retry) && retry > 0 ? retry : null);
			}
			if (!res.ok) {
				await res.body?.cancel();
				throw new Error(`OpenSky ${res.status} ${res.statusText}`.trim());
			}
			const body = (await res.json()) as { states?: unknown[] | null };
			return {
				states: Array.isArray(body.states) ? body.states : [],
				creditsRemaining: remaining !== null && remaining !== '' ? Number(remaining) : null
			};
		}
		throw new Error('OpenSky rejected the access token twice');
	}
}
