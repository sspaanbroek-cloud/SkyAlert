import assert from 'node:assert/strict';
import type { ClaimedAlert } from '../_shared/notify.ts';
import { createHandler, type Subscription } from './handler.ts';

const alert = (id: number, user: string): ClaimedAlert => ({
	alert_id: id, user_id: user, spot_id: 's', spot_name: 'Spot', time_zone: 'UTC', prediction_id: id * 10,
	basis: 'live_adsb', callsign: `ABC${id}`, icao24: null, closest_approach_at: new Date(Date.now() + 6 * 60_000).toISOString(),
	closest_distance_nm: 1, altitude_ft: 30000, azimuth_deg: 90, elevation_deg: 50, rating: 'clear', manual: false
});
const sub = (user: string, endpoint: string): Subscription => ({ user_id: user, endpoint, p256dh: 'p', auth: 'a' });

function setup(alerts: ClaimedAlert[], subs: Subscription[], status: Record<string, number>) {
	const calls: { fn: string; args?: Record<string, unknown> }[] = [];
	const sent: { endpoint: string; title: string }[] = [];
	const h = createHandler({
		secret: 's', log: () => {},
		rpc: async <T>(fn: string, args?: Record<string, unknown>) => {
			calls.push({ fn, args });
			if (fn === 'queue_alerts') return { data: 2 as T, error: null };
			if (fn === 'claim_due_alerts') return { data: alerts as T, error: null };
			return { data: null, error: null };
		},
		subscriptions: async (ids) => subs.filter((s) => ids.includes(s.user_id)),
		send: async (s, payload) => {
			sent.push({ endpoint: s.endpoint, title: payload.title });
			const code = status[s.endpoint] ?? 201;
			return code < 300 ? { ok: true, status: code } : { ok: false, status: code };
		}
	});
	const post = (secret = 's') => h(new Request('http://x/', { method: 'POST', headers: { 'x-ingest-secret': secret } }));
	return { post, calls, sent };
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
	assert.deepEqual(body, { queued: 2, claimed: 3, delivered: 1, undelivered: 2, removed_subscriptions: 1 });
	assert.equal(sent.length, 3);
	assert.match(sent[0].title, /^ABC1 overhead in [56] min$/);
	const results = calls.find((c) => c.fn === 'complete_alerts')!.args!.results as Record<string, unknown>[];
	assert.deepEqual(results.map((r) => [r.alert_id, r.delivered, r.failed, r.gone, r.detail]), [
		[1, 1, 1, [], '500'],
		[2, 0, 0, ['https://p/old'], '410 gone'],
		[3, 0, 0, [], 'no devices subscribed']
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
