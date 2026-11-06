// send-alerts: queue automatic alerts, claim due ones, deliver them by Web
// Push and/or text message, whichever each person has switched on.
import { buildPayload, type ClaimedAlert, type PushPayload } from '../_shared/notify.ts';
import { buildSms, type SmsResult, TWILIO_OPTED_OUT } from '../_shared/sms.ts';
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

interface Channel {
	user_id: string;
	push_enabled: boolean;
	sms_to: string | null;
	sms_blocked_reason: string | null;
}

export interface Deps {
	rpc: <T>(fn: string, args?: Record<string, unknown>) => Promise<RpcResult<T>>;
	subscriptions: (userIds: string[]) => Promise<Subscription[]>;
	send: (sub: Subscription, payload: PushPayload) => Promise<SendResult>;
	/** Undefined when no texting service is configured: texts are skipped. */
	sendSms?: (to: string, body: string) => Promise<SmsResult>;
	secret: string | undefined;
	smsDailyCap?: number;
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

		const userIds = [...new Set(alerts.map((a) => a.user_id))];
		const ch = await deps.rpc<Channel[]>('alert_channels', { p_user_ids: userIds, p_daily_cap: deps.smsDailyCap ?? 20 });
		if (ch.error) return json(500, { error: `alert_channels: ${ch.error.message}` });
		const channels = new Map((ch.data ?? []).map((c) => [c.user_id, c]));

		const subs = await deps.subscriptions(userIds);
		const byUser = new Map<string, Subscription[]>();
		for (const s of subs) byUser.set(s.user_id, [...(byUser.get(s.user_id) ?? []), s]);

		const okEndpoints = new Set<string>();
		const failedEndpoints = new Set<string>();
		const optedOut = new Set<string>();
		const deliveries: { alert_id: number; user_id: string; channel: 'push' | 'sms'; ok: boolean; detail: string | null }[] = [];
		const results = [];
		let textsSent = 0;

		for (const a of alerts) {
			const c = channels.get(a.user_id);
			const pushOn = c?.push_enabled ?? true;
			let delivered = 0;
			let failed = 0;
			const gone: string[] = [];
			const details: string[] = [];

			const devices = pushOn ? (byUser.get(a.user_id) ?? []) : [];
			if (devices.length) {
				const payload = buildPayload(a, deps.now?.());
				for (const sub of devices) {
					const r = await deps.send(sub, payload);
					if (r.ok) {
						delivered++;
						okEndpoints.add(sub.endpoint);
					} else if (r.status === 404 || r.status === 410) {
						gone.push(sub.endpoint);
						details.push(`push ${r.status} gone`);
					} else {
						failed++;
						failedEndpoints.add(sub.endpoint);
						details.push(`push ${r.status ?? r.error ?? 'error'}`);
					}
				}
				deliveries.push({ alert_id: a.alert_id, user_id: a.user_id, channel: 'push', ok: delivered > 0, detail: details.join(', ') || null });
			}

			if (c?.sms_to) {
				if (!deps.sendSms) {
					details.push('texting not configured');
				} else {
					const r = await deps.sendSms(c.sms_to, buildSms(a, deps.now?.()));
					if (r.ok) {
						delivered++;
						textsSent++;
					} else {
						failed++;
						if (r.code === TWILIO_OPTED_OUT) optedOut.add(a.user_id);
						details.push(`sms ${r.code ?? r.status ?? ''} ${r.error ?? ''}`.trim());
					}
					deliveries.push({ alert_id: a.alert_id, user_id: a.user_id, channel: 'sms', ok: r.ok, detail: r.ok ? null : details.at(-1)! });
				}
			} else if (c?.sms_blocked_reason) {
				details.push(`text skipped: ${c.sms_blocked_reason}`);
			}

			if (!devices.length && !c?.sms_to) details.push('no way to reach this person');
			results.push({ alert_id: a.alert_id, delivered, failed, gone, detail: details.join(', ') || null });
		}

		const done = await deps.rpc('complete_alerts', { results });
		if (done.error) return json(500, { error: `complete_alerts: ${done.error.message}` });
		await deps.rpc('mark_push_results', { ok_endpoints: [...okEndpoints], failed_endpoints: [...failedEndpoints] });
		if (deliveries.length) await deps.rpc('record_deliveries', { rows: deliveries });
		if (optedOut.size) await deps.rpc('mark_sms_opted_out', { p_user_ids: [...optedOut] });

		const summary = {
			queued: queued.data,
			claimed: alerts.length,
			delivered: results.filter((r) => r.delivered > 0).length,
			undelivered: results.filter((r) => r.delivered === 0).length,
			texts_sent: textsSent,
			texting_configured: Boolean(deps.sendSms),
			opted_out: optedOut.size,
			removed_subscriptions: results.reduce((n, r) => n + r.gone.length, 0)
		};
		if (summary.undelivered) log('send-alerts: some alerts not delivered', results);
		return json(200, summary);
	};
}
