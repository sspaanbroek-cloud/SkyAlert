// Open-Meteo forecast API client for model cloud cover (https://open-meteo.com/en/docs).
//
// Free for non-commercial use without a key (attribution: CC BY 4.0). With an
// API key (commercial plans) requests go to customer-api.open-meteo.com.
// One request can carry many locations as comma-separated lists; the answer
// is then a JSON array in the same order.

export const OPEN_METEO_URL = 'https://api.open-meteo.com/v1/forecast';
export const OPEN_METEO_CUSTOMER_URL = 'https://customer-api.open-meteo.com/v1/forecast';

export interface ModelPoint {
	cell_key: string;
	lat: number;
	lon: number;
}

/** Shape sent to public.ingest_model_cloud(). */
export interface ModelCloudRow extends ModelPoint {
	valid_at: string;
	low: number | null;
	mid: number | null;
	high: number | null;
	model: string;
}

export interface OpenMeteoOptions {
	fetch?: typeof fetch;
	apiKey?: string;
	userAgent: string;
	forecastDays?: number;
	timeoutMs?: number;
}

export function cloudUrl(points: ModelPoint[], opts: Pick<OpenMeteoOptions, 'apiKey' | 'forecastDays'> = {}): string {
	const q = new URLSearchParams({
		latitude: points.map((p) => p.lat).join(','),
		longitude: points.map((p) => p.lon).join(','),
		hourly: 'cloud_cover_low,cloud_cover_mid,cloud_cover_high',
		forecast_days: String(opts.forecastDays ?? 2),
		past_hours: '1',
		timeformat: 'unixtime',
		timezone: 'GMT'
	});
	if (opts.apiKey) q.set('apikey', opts.apiKey);
	return `${opts.apiKey ? OPEN_METEO_CUSTOMER_URL : OPEN_METEO_URL}?${q}`;
}

const pct = (v: unknown): number | null =>
	typeof v === 'number' && Number.isFinite(v) ? Math.max(0, Math.min(100, Math.round(v))) : null;

/** Turn one location's response into rows (hours with no data are skipped). */
export function parseCloudResponse(point: ModelPoint, body: unknown): ModelCloudRow[] {
	const h = (body as { hourly?: Record<string, unknown[]> })?.hourly;
	if (!h || !Array.isArray(h.time)) return [];
	const rows: ModelCloudRow[] = [];
	h.time.forEach((t, i) => {
		if (typeof t !== 'number') return;
		const low = pct(h.cloud_cover_low?.[i]);
		const mid = pct(h.cloud_cover_mid?.[i]);
		const high = pct(h.cloud_cover_high?.[i]);
		if (low === null && mid === null && high === null) return;
		rows.push({ ...point, valid_at: new Date(t * 1000).toISOString(), low, mid, high, model: 'best_match' });
	});
	return rows;
}

export async function fetchModelCloud(points: ModelPoint[], opts: OpenMeteoOptions): Promise<ModelCloudRow[]> {
	if (points.length === 0) return [];
	const res = await (opts.fetch ?? fetch)(cloudUrl(points, opts), {
		headers: { 'User-Agent': opts.userAgent, Accept: 'application/json' },
		signal: AbortSignal.timeout(opts.timeoutMs ?? 20000)
	});
	if (!res.ok) {
		const reason = await res.text().catch(() => '');
		throw new Error(`Open-Meteo ${res.status}${reason ? `: ${reason.slice(0, 200)}` : ''}`);
	}
	const body = await res.json();
	const list = Array.isArray(body) ? body : [body];
	if (list.length !== points.length) throw new Error(`Open-Meteo returned ${list.length} locations for ${points.length}`);
	return points.flatMap((p, i) => parseCloudResponse(p, list[i]));
}
