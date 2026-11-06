import assert from 'node:assert/strict';
import { buildSms, TWILIO_OPTED_OUT, twilioSender } from './sms.ts';
import type { ClaimedAlert } from './notify.ts';

const now = new Date('2026-11-05T03:36:00Z');
const a: ClaimedAlert = {
	alert_id: 1, user_id: 'u', spot_id: 's', spot_name: 'Kubota Garden', time_zone: 'America/Los_Angeles',
	prediction_id: 42, basis: 'live_adsb', callsign: 'ASA123', icao24: 'a1b2c3',
	closest_approach_at: '2026-11-05T03:42:00Z', closest_distance_nm: 1.2, altitude_ft: 33000,
	azimuth_deg: 45, elevation_deg: 62.4, rating: 'clear', manual: false
};

Deno.test('text wording: brand first, STOP last, one message', () => {
	const t = buildSms(a, now);
	assert.equal(t, 'SkyAlert: ASA123 overhead in 6 min. Clear view, 33,000 ft, look NE 62 deg up, 7:42pm. Kubota Garden. Reply STOP to opt out.');
	assert.ok(t.length <= 160);
});

Deno.test('long or fancy spot names are shortened to plain characters', () => {
	const t = buildSms({ ...a, spot_name: 'Café hill above the long winding river road near the old orchard — north side', basis: 'recurring' }, now);
	assert.ok(t.length <= 160, `${t.length}`);
	assert.match(t, /^SkyAlert: /);
	assert.match(t, /Usual flight, not yet tracked\./);
	assert.match(t, / Reply STOP to opt out\.$/);
	assert.doesNotMatch(t, /[^\x20-\x7e]/);
});

Deno.test('Twilio request and STOP error', async () => {
	const calls: { url: string; init: RequestInit }[] = [];
	const send = twilioSender({
		accountSid: 'AC123', authToken: 'tok', messagingServiceSid: 'MG456',
		fetch: (async (url: string, init: RequestInit) => {
			calls.push({ url, init });
			const to = new URLSearchParams(String(init.body)).get('To');
			return to === '+15550000000'
				? Response.json({ code: 21610, message: 'Attempt to send to unsubscribed recipient' }, { status: 400 })
				: Response.json({ sid: 'SM1' }, { status: 201 });
		}) as typeof fetch
	});
	assert.deepEqual(await send('+14155550101', 'hi'), { ok: true, status: 201 });
	assert.equal(calls[0].url, 'https://api.twilio.com/2010-04-01/Accounts/AC123/Messages.json');
	assert.equal(new Headers(calls[0].init.headers).get('authorization'), 'Basic ' + btoa('AC123:tok'));
	assert.equal(String(calls[0].init.body), 'To=%2B14155550101&MessagingServiceSid=MG456&Body=hi');
	const r = await send('+15550000000', 'hi');
	assert.equal(r.ok, false);
	assert.equal(r.code, TWILIO_OPTED_OUT);
});
