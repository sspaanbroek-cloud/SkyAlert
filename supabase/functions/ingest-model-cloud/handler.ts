// ingest-model-cloud: hourly model cloud cover for every spot cell, then
// re-rate current passes. Dependencies injected for testing.
import { type ModelCloudRow, type ModelPoint, fetchModelCloud } from '../_shared/openmeteo.ts';
import { type RpcResult, timingSafeEqual } from '../ingest-metar/handler.ts';

export interface Deps {
	rpc: <T>(fn: string, args?: Record<string, unknown>) => Promise<RpcResult<T>>;
	fetch?: typeof fetch;
	apiKey?: string;
	secret: string | undefined;
	userAgent: string;
	log?: (msg: string, extra?: unknown) => void;
}

const POINTS_PER_REQUEST = 100;

const json = (status: number, body: unknown) =>
	new Response(JSON.stringify(body), { status, headers: { 'Content-Type': 'application/json' } });

export function createHandler(deps: Deps) {
	const log = deps.log ?? ((msg: string, extra?: unknown) => console.log(msg, extra ?? ''));
	return async function handle(req: Request): Promise<Response> {
		if (req.method !== 'POST') return json(405, { error: 'POST only' });
		if (!deps.secret) return json(500, { error: 'INGEST_SECRET is not configured' });
		if (!timingSafeEqual(req.headers.get('x-ingest-secret') ?? '', deps.secret)) return json(401, { error: 'unauthorized' });

		const pts = await deps.rpc<ModelPoint[]>('model_cloud_points');
		if (pts.error) return json(500, { error: `model_cloud_points: ${pts.error.message}` });
		const points = pts.data ?? [];
		if (points.length === 0) return json(200, { points: 0, note: 'no spots yet' });

		const rows: ModelCloudRow[] = [];
		const errors: string[] = [];
		for (let i = 0; i < points.length; i += POINTS_PER_REQUEST) {
			try {
				rows.push(...(await fetchModelCloud(points.slice(i, i + POINTS_PER_REQUEST), deps)));
			} catch (e) {
				errors.push((e as Error).message);
			}
		}
		if (rows.length === 0) {
			log('ingest-model-cloud: nothing fetched', errors);
			return json(502, { points: points.length, errors });
		}

		const stored = await deps.rpc('ingest_model_cloud', { points: rows });
		if (stored.error) return json(500, { error: `ingest_model_cloud: ${stored.error.message}` });
		const vis = await deps.rpc('refresh_visibility_assessments');
		if (vis.error) return json(500, { error: `refresh_visibility_assessments: ${vis.error.message}` });

		if (errors.length) log('ingest-model-cloud: partial', errors);
		return json(200, { points: points.length, rows: rows.length, stored: stored.data, visibility: vis.data, errors });
	};
}
