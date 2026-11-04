// Request handler for the ingest-metar function, with its dependencies passed
// in so it can be tested without network or database.
import { type Box, fetchMetarsInBox } from '../_shared/awc.ts';
import { type IngestRecord, parseAwcMetar } from '../_shared/metar.ts';

export interface RpcResult<T> {
	data: T | null;
	error: { message: string } | null;
}

export interface Deps {
	rpc: <T>(fn: string, args?: Record<string, unknown>) => Promise<RpcResult<T>>;
	fetch?: typeof fetch;
	/** Shared secret the scheduler sends in `x-ingest-secret`. */
	secret: string | undefined;
	userAgent: string;
	sleep?: (ms: number) => Promise<void>;
	log?: (msg: string, extra?: unknown) => void;
}

interface IngestSummary {
	stored: number;
	unchanged: number;
	rejected: { station: string; observed_at?: string; error: string }[];
}

const BATCH = 250;

export function timingSafeEqual(a: string, b: string): boolean {
	const enc = new TextEncoder();
	const x = enc.encode(a);
	const y = enc.encode(b);
	let diff = x.length ^ y.length;
	for (let i = 0; i < Math.max(x.length, y.length); i++) diff |= (x[i] ?? 0) ^ (y[i] ?? 0);
	return diff === 0;
}

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

		const areas = await deps.rpc<Box[]>('metar_fetch_areas');
		if (areas.error) return json(500, { error: `metar_fetch_areas: ${areas.error.message}` });
		const boxes = areas.data ?? [];
		if (boxes.length === 0) return json(200, { areas: 0, fetched: 0, stored: 0, note: 'no spots yet' });

		// Fetch areas one at a time: gentle on AWC, and the volume is small.
		const fetchErrors: string[] = [];
		const raw: unknown[] = [];
		for (const box of boxes) {
			try {
				raw.push(...(await fetchMetarsInBox(box, { fetch: deps.fetch, userAgent: deps.userAgent, sleep: deps.sleep })));
			} catch (e) {
				fetchErrors.push(`${JSON.stringify(box)}: ${(e as Error).message}`);
			}
		}
		if (fetchErrors.length === boxes.length) {
			log('ingest-metar: every AWC request failed', fetchErrors);
			return json(502, { error: 'AWC unavailable', fetch_errors: fetchErrors });
		}

		// Parse, and drop duplicates where boxes overlap.
		const byKey = new Map<string, IngestRecord>();
		const parseRejected: { station: string; reason: string }[] = [];
		for (const item of raw) {
			const p = parseAwcMetar(item);
			if (!p.ok) {
				parseRejected.push({ station: p.station, reason: p.reason });
				continue;
			}
			byKey.set(`${p.record.station.icao}|${p.record.observed_at}`, p.record);
		}
		const records = [...byKey.values()];

		const total: IngestSummary = { stored: 0, unchanged: 0, rejected: [] };
		for (let i = 0; i < records.length; i += BATCH) {
			const res = await deps.rpc<IngestSummary>('ingest_metars', { reports: records.slice(i, i + BATCH) });
			if (res.error || !res.data) {
				return json(500, { error: `ingest_metars: ${res.error?.message ?? 'no result'}`, ...total });
			}
			total.stored += res.data.stored;
			total.unchanged += res.data.unchanged;
			total.rejected.push(...res.data.rejected);
		}

		const summary = {
			areas: boxes.length,
			fetched: raw.length,
			parsed: records.length,
			stored: total.stored,
			unchanged: total.unchanged,
			parse_rejected: parseRejected,
			db_rejected: total.rejected,
			fetch_errors: fetchErrors
		};
		if (parseRejected.length || total.rejected.length || fetchErrors.length) log('ingest-metar: partial', summary);
		return json(200, summary);
	};
}
