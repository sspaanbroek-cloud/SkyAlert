import assert from 'node:assert/strict';
import type { ClaimedAlert } from '../_shared/notify.ts';
import { createHandler, type Subscription } from './handler.ts';

const alert = (id: number, user: string): ClaimedAlert => ({
	alert_id: id, user_id: user, spot_id: 's', spot_name: 'Spot', time_zone: 'UTC', prediction_id: id * 10,
	basis: 'live_adsb', callsign: `ABC${id}`, icao24: null, closest_approach_at: new Date(Date.now() + 6 * 60_000).toISOString(),
	closest_distance_nm: 1, altitude_ft: 30000, azimuth_deg: 90, elevation_deg: 50, rating: 'clear', manual: false
});
const sub = (user: string, endpoint: string): Subscription => ({ user_id: user, endpoint, p256dh: 'p', auth: 'a' });

type Ch = { user_id: string; push_enabled: boolean; sms_to: string | null; sms_blocked_reason: string | null };

function setup(alerts: ClaimedAlert[], subs: Subscription[], status: Record<string, number>, opts: {
	channels?: Ch[]; sms?: (to: string, body: string) => { ok: boolean; code?: number } } = {}) {
	const calls: { fn: string; args?: Record<string, unknown> }[] = [];
	const sent: { endpoint: string; title: string }[] = [];
	const texts: { to: string; body: string }[] = [];
	const h = createHandler({
		secret: 's', log: () => {},
		rpc: async <T>(fn: string, args?: Record<string, unknown>) => {
			calls.push({ fn, args });
			if (fn === 'queue_alerts') return { data: 2 as T, error: null };
			if (fn === 'claim_due_alerts') return { data: alerts as T, error: null };
			if (fn === 'alert_channels') {
				const ids = args!.p_user_ids as string[];
				return { data: ids.map((id) => opts.channels?.find((c) => c.user_id === id) ?? { user_id: id, push_enabled: true, sms_to: null, sms_blocked_reason: null }) as T, error: null };
			}
			return { data: null, error: null };
		},
		subscriptions: async (ids) => subs.filter((s) => ids.includes(s.user_id)),
		sendSms: opts.sms ? async (to, body) => (texts.push({ to, body }), opts.sms!(to, body)) : undefined,
		send: async (s, payload) => {
			sent.push({ endpoint: s.endpoint, title: payload.title });
			const code = status[s.endpoint] ?? 201;
			return code < 300 ? { ok: true, status: code } : { ok: false, status: code };
		}
	});
	const post = (secret = 's') => h(new Request('http://x/', { method: 'POST', headers: { 'x-ingest-secret': secret } }));
	return { post, calls, sent, texts };
}

Deno.test('auth required', async () => {
	assert.equal((await setup([], [], {}).post('x')).status, 401);
});

Deno.test('delivers to every device; gone endpoints removed; failures recorded', async () => {
	const { post, calls, sent } = setup(
		[alert(1, 'u1'), alert(2, 'u2'), alert(3, 'u3')],
		[sub('u1', 'https://p/phone'), sub('u1', 'https://p/laptop'), sub('u2', 'https://p/old')],
		{ 'https://p/laptop': 500, 'https://p/old': 410 }
	);
	const body = await (await post()).json();
	assert.deepEqual(body, { queued: 2, claimed: 3, delivered: 1, undelivered: 2, texts_sent: 0, texting_configured: false, opted_out: 0, removed_subscriptions: 1 });
	assert.equal(sent.length, 3);
	assert.match(sent[0].title, /^ABC1 overhead in [56] min$/);
	const results = calls.find((c) => c.fn === 'complete_alerts')!.args!.results as Record<string, unknown>[];
	assert.deepEqual(results.map((r) => [r.alert_id, r.delivered, r.failed, r.gone, r.detail]), [
		[1, 1, 1, [], 'push 500'],
		[2, 0, 0, ['https://p/old'], 'push 410 gone'],
		[3, 0, 0, [], 'no way to reach this person']
	]);
	assert.deepEqual(calls.find((c) => c.fn === 'mark_push_results')!.args, {
		ok_endpoints: ['https://p/phone'],
		failed_endpoints: ['https://p/laptop']
	});
});

Deno.test('nothing due: no sends', async () => {
	const { post, sent, calls } = setup([], [sub('u1', 'https://p/phone')], {});
	assert.deepEqual(await (await post()).json(), { queued: 2, sent: 0 });
	assert.equal(sent.length, 0);
	assert.equal(calls.some((c) => c.fn === 'complete_alerts'), false);
});

Deno.test('texts: sent to the verified number, STOP recorded, push turned off respected', async () => {
	const { post, calls, sent, texts } = setup(
		[alert(1, 'u1'), alert(2, 'u2'), alert(3, 'u3')],
		[sub('u1', 'https://p/phone'), sub('u3', 'https://p/u3')],
		{},
		{
			channels: [
				{ user_id: 'u1', push_enabled: true, sms_to: '+14155550101', sms_blocked_reason: null },
				{ user_id: 'u2', push_enabled: true, sms_to: '+15550000000', sms_blocked_reason: null },
				{ user_id: 'u3', push_enabled: false, sms_to: null, sms_blocked_reason: 'daily text limit reached' }
			],
			sms: (to) => (to === '+15550000000' ? { ok: false, code: 21610 } : { ok: true })
		}
	);
	const body = await (await post()).json();
	assert.equal(body.texts_sent, 1);
	assert.equal(body.opted_out, 1);
	assert.deepEqual(sent.map((s) => s.endpoint), ['https://p/phone'], 'u3 has push off: no push');
	assert.deepEqual(texts.map((t) => t.to), ['+14155550101', '+15550000000']);
	assert.match(texts[0].body, /^SkyAlert: ABC1 overhead in [56] min\./);
	assert.deepEqual(calls.find((c) => c.fn === 'mark_sms_opted_out')!.args, { p_user_ids: ['u2'] });
	const rows = calls.find((c) => c.fn === 'record_deliveries')!.args!.rows as { user_id: string; channel: string; ok: boolean }[];
	assert.deepEqual(rows.map((r) => `${r.user_id}:${r.channel}:${r.ok}`), ['u1:push:true', 'u1:sms:true', 'u2:sms:false']);
	const results = calls.find((c) => c.fn === 'complete_alerts')!.args!.results as { alert_id: number; detail: string }[];
	assert.match(results[2].detail, /text skipped: daily text limit reached/);
});

Deno.test('texting not configured: alert still delivered by push, text noted', async () => {
	const { post, calls } = setup([alert(1, 'u1')], [sub('u1', 'https://p/phone')], {}, {
		channels: [{ user_id: 'u1', push_enabled: true, sms_to: '+14155550101', sms_blocked_reason: null }]
	});
	const body = await (await post()).json();
	assert.equal(body.delivered, 1);
	assert.equal(body.texting_configured, false);
	const results = calls.find((c) => c.fn === 'complete_alerts')!.args!.results as { detail: string }[];
	assert.match(results[0].detail, /texting not configured/);
});
