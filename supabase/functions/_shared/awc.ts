// Aviation Weather Center data API client (https://aviationweather.gov/data/api/).
// Free, no key. AWC asks clients to identify themselves and stay under
// 100 requests/minute; the ingest makes one request per area every 10 minutes.

export const AWC_METAR_URL = 'https://aviationweather.gov/api/data/metar';

export interface Box {
	min_lat: number;
	min_lon: number;
	max_lat: number;
	max_lon: number;
}

export interface AwcOptions {
	fetch?: typeof fetch;
	userAgent: string;
	/** Hours of history to request. 2 catches the last routine report plus SPECIs. */
	hours?: number;
	timeoutMs?: number;
	sleep?: (ms: number) => Promise<void>;
}

const r2 = (n: number) => Math.round(n * 100) / 100;

export function metarUrl(box: Box, hours = 2): string {
	const bbox = [box.min_lat, box.min_lon, box.max_lat, box.max_lon].map(r2).join(',');
	return `${AWC_METAR_URL}?bbox=${bbox}&format=json&hours=${hours}`;
}

/** Fetch raw AWC METAR objects in a box. Throws on HTTP or network errors. */
export async function fetchMetarsInBox(box: Box, opts: AwcOptions): Promise<unknown[]> {
	const doFetch = opts.fetch ?? fetch;
	const sleep = opts.sleep ?? ((ms: number) => new Promise((r) => setTimeout(r, ms)));
	const url = metarUrl(box, opts.hours ?? 2);

	for (let attempt = 0; attempt < 2; attempt++) {
		const res = await doFetch(url, {
			headers: { 'User-Agent': opts.userAgent, Accept: 'application/json' },
			signal: AbortSignal.timeout(opts.timeoutMs ?? 20000)
		});
		if (res.status === 204) return [];
		if (res.status === 429 && attempt === 0) {
			const wait = Math.min(Number(res.headers.get('Retry-After')) || 5, 15);
			await res.body?.cancel();
			await sleep(wait * 1000);
			continue;
		}
		if (!res.ok) {
			await res.body?.cancel();
			throw new Error(`AWC ${res.status} ${res.statusText}`.trim());
		}
		const text = await res.text();
		if (!text.trim()) return [];
		const body = JSON.parse(text);
		if (!Array.isArray(body)) throw new Error('AWC returned something other than a JSON array');
		return body;
	}
	throw new Error('AWC rate limited the request twice');
}
