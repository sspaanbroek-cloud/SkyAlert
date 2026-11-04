import assert from 'node:assert/strict';
import { buildPayload, type ClaimedAlert } from './notify.ts';

const now = new Date('2026-11-05T03:36:00Z');
const a: ClaimedAlert = {
	alert_id: 1, user_id: 'u', spot_id: 'spot-1', spot_name: 'Kubota Garden', time_zone: 'America/Los_Angeles',
	prediction_id: 42, basis: 'live_adsb', callsign: 'ASA123', icao24: 'a1b2c3',
	closest_approach_at: '2026-11-05T03:42:00Z', closest_distance_nm: '1.20', altitude_ft: 33000,
	azimuth_deg: '45.0', elevation_deg: '62.4', rating: 'clear', manual: false
};

Deno.test('payload for a live pass', () => {
	assert.deepEqual(buildPayload(a, now), {
		title: 'ASA123 overhead in 6 min',
		body: 'Clear view · 33,000 ft · look NE, 62° up · at 7:42 pm\nKubota Garden',
		tag: 'pass-42',
		url: '/spots/spot-1'
	});
});

Deno.test('overhead now, straight up, hex id, usual flight', () => {
	const p = buildPayload({ ...a, callsign: null, elevation_deg: 85, basis: 'recurring', rating: 'partial',
	                         closest_approach_at: '2026-11-05T03:36:30Z' }, now);
	assert.equal(p.title, 'A1B2C3 overhead now');
	assert.equal(p.body, 'Partly visible · 33,000 ft · straight overhead · at 7:36 pm\nKubota Garden (usual flight, not yet tracked)');
});
