// send-alerts: queue automatic alerts, claim due ones, deliver by Web Push.
import { buildPayload, type ClaimedAlert, type PushPayload } from '../_shared/notify.ts';
import { type RpcResult, timingSafeEqual } from '../ingest-metar/handler.ts';

export interface Subscription {
	user_id: string;
	endpoint: string;
	p256dh: string;
	auth: string;
}

export interface SendResult {
	ok: boolean;
	status?: number;
	error?: string;
}

export interface Deps {
	rpc: <T>(fn: string, args?: Record<string, unknown>) => Promise<RpcResult<T>>;
	subscriptions: (userIds: string[]) => Promise<Subscription[]>;
	send: (sub: Subscription, payload: PushPayload) => Promise<SendResult>;
	secret: string | undefined;
	now?: () => Date;
	log?: (msg: string, extra?: unknown) => void;
}

const json = (status: number, body: unknown) =>
	new Response(JSON.stringify(body), { status, headers: { 'Content-Type': 'application/json' } });

export function createHandler(deps: Deps) {
	const log = deps.log ?? ((msg: string, extra?: unknown) => console.log(msg, extra ?? ''));
	return async function handle(req: Request): Promise<Response> {
		if (req.method !== 'POST') return json(405, { error: 'POST only' });
		if (!deps.secret) return json(500, { error: 'INGEST_SECRET is not configured' });
		if (!timingSafeEqual(req.headers.get('x-ingest-secret') ?? '', deps.secret)) return json(401, { error: 'unauthorized' });

		const queued = await deps.rpc<number>('queue_alerts');
		if (queued.error) return json(500, { error: `queue_alerts: ${queued.error.message}` });
		const claimed = await deps.rpc<ClaimedAlert[]>('claim_due_alerts');
		if (claimed.error) return json(500, { error: `claim_due_alerts: ${claimed.error.message}` });
		const alerts = claimed.data ?? [];
		if (alerts.length === 0) return json(200, { queued: queued.data, sent: 0 });

		const subs = await deps.subscriptions([...new Set(alerts.map((a) => a.user_id))]);
		const byUser = new Map<string, Subscription[]>();
		for (const s of subs) byUser.set(s.user_id, [...(byUser.get(s.user_id) ?? []), s]);

		const okEndpoints = new Set<string>();
		const failedEndpoints = new Set<string>();
		const results = [];
		for (const a of alerts) {
			const payload = buildPayload(a, deps.now?.());
			let delivered = 0;
			let failed = 0;
			const gone: string[] = [];
			const details: string[] = [];
			for (const sub of byUser.get(a.user_id) ?? []) {
				const r = await deps.send(sub, payload);
				if (r.ok) {
					delivered++;
					okEndpoints.add(sub.endpoint);
				} else if (r.status === 404 || r.status === 410) {
					gone.push(sub.endpoint); // browser revoked the subscription
					details.push(`${r.status} gone`);
				} else {
					failed++;
					failedEndpoints.add(sub.endpoint);
					details.push(r.status ? `${r.status}` : r.error ?? 'error');
				}
			}
			if ((byUser.get(a.user_id) ?? []).length === 0) details.push('no devices subscribed');
			results.push({ alert_id: a.alert_id, delivered, failed, gone, detail: details.join(', ') || null });
		}

		const done = await deps.rpc('complete_alerts', { results });
		if (done.error) return json(500, { error: `complete_alerts: ${done.error.message}` });
		await deps.rpc('mark_push_results', { ok_endpoints: [...okEndpoints], failed_endpoints: [...failedEndpoints] });

		const summary = {
			queued: queued.data,
			claimed: alerts.length,
			delivered: results.filter((r) => r.delivered > 0).length,
			undelivered: results.filter((r) => r.delivered === 0).length,
			removed_subscriptions: results.reduce((n, r) => n + r.gone.length, 0)
		};
		if (summary.undelivered) log('send-alerts: some alerts not delivered', results);
		return json(200, summary);
	};
}
