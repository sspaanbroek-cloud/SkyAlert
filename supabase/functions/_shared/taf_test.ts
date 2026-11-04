import assert from 'node:assert/strict';
import { parseAwcTaf } from './taf.ts';

// Shape of one object from https://aviationweather.gov/api/data/taf?format=json
const t0 = 1793804400; // 2026-11-04T15:00:00Z
const awcTaf = {
	icaoId: 'KSEA',
	issueTime: '2026-11-04T14:40:00.000Z',
	validTimeFrom: t0,
	validTimeTo: t0 + 30 * 3600,
	rawTAF: 'TAF KSEA 041440Z 0415/0521 18008KT P6SM BKN060 FM042100 20012KT P6SM OVC030 TEMPO 0418/0420 4SM -SHRA BKN025 BECMG 0500/0502 SCT040 PROB30 0506/0510 2SM BR OVC008',
	lat: 47.4447,
	lon: -122.3144,
	elev: 132,
	name: 'Seattle-Tacoma Intl, WA, US',
	fcsts: [
		{ timeFrom: t0, timeTo: t0 + 6 * 3600, fcstChange: null, wdir: 180, wspd: 8, visib: '6+',
		  clouds: [{ cover: 'BKN', base: 6000, type: null }] },
		{ timeFrom: t0 + 6 * 3600, timeTo: t0 + 30 * 3600, fcstChange: 'FM', wdir: 200, wspd: 12, visib: '6+',
		  clouds: [{ cover: 'OVC', base: 3000, type: null }] },
		{ timeFrom: t0 + 3 * 3600, timeTo: t0 + 5 * 3600, fcstChange: 'TEMPO', visib: 4, wxString: '-SHRA',
		  clouds: [{ cover: 'BKN', base: 2500, type: null }] },
		{ timeFrom: t0 + 9 * 3600, timeTo: t0 + 11 * 3600, fcstChange: 'BECMG', clouds: [{ cover: 'SCT', base: 4000, type: 'CB' }] },
		{ timeFrom: t0 + 15 * 3600, timeTo: t0 + 19 * 3600, fcstChange: 'PROB', probability: 30, visib: 2, wxString: 'BR',
		  clouds: [{ cover: 'OVC', base: 800, type: null }] },
		{ timeFrom: t0 + 20 * 3600, timeTo: t0 + 30 * 3600, fcstChange: 'BECMG', wdir: 220, wspd: 10, clouds: [] },
		{ timeFrom: t0 + 22 * 3600, fcstChange: 'FM', visib: '6+', clouds: [{ cover: 'SKC' }] }
	]
};

Deno.test('parseAwcTaf: header and periods', () => {
	const r = parseAwcTaf(awcTaf);
	assert.ok(r.ok);
	assert.equal(r.record.station.elevation_ft, 433);
	assert.equal(r.record.issued_at, '2026-11-04T14:40:00.000Z');
	assert.equal(r.record.valid_from, '2026-11-04T15:00:00.000Z');
	assert.equal(r.record.valid_to, '2026-11-05T21:00:00.000Z');
	assert.deepEqual(r.record.periods.map((p) => p.change_type), ['BASE', 'FM', 'TEMPO', 'BECMG', 'PROB', 'BECMG', 'FM']);
});

Deno.test('parseAwcTaf: period details', () => {
	const r = parseAwcTaf(awcTaf);
	assert.ok(r.ok);
	const [base, , tempo, becmg, prob, windOnly, skc] = r.record.periods;
	assert.deepEqual(base.layers, [{ cover: 'BKN', base_agl_ft: 6000, cloud_type: null }]);
	assert.equal(base.visibility_sm, 6);
	assert.equal(base.visibility_is_min, true);
	assert.equal(tempo.wx_string, '-SHRA');
	assert.equal(becmg.layers?.[0].cloud_type, 'CB');
	assert.equal(becmg.visibility_sm, null); // not mentioned: carries over
	assert.equal(prob.probability, 30);
	assert.equal(windOnly.layers, null, 'wind-only BECMG leaves cloud unchanged');
	assert.equal(skc.sky_clear_code, 'SKC');
	assert.deepEqual(skc.layers, []);
	assert.equal(skc.time_to, null);
});

Deno.test('parseAwcTaf: vertical visibility becomes a VV layer', () => {
	const r = parseAwcTaf({ ...awcTaf, fcsts: [{ timeFrom: t0, fcstChange: null, visib: 0.25, vertVis: 200, clouds: [] }] });
	assert.ok(r.ok);
	assert.deepEqual(r.record.periods[0].layers, [{ cover: 'VV', base_agl_ft: 200, cloud_type: null }]);
});

Deno.test('parseAwcTaf: rejects incomplete TAFs', () => {
	assert.equal((parseAwcTaf({ ...awcTaf, fcsts: [] }) as { reason: string }).reason, 'no forecast periods');
	assert.equal((parseAwcTaf({ ...awcTaf, validTimeTo: null }) as { reason: string }).reason, 'missing issue or validity time');
	assert.equal((parseAwcTaf({ ...awcTaf, rawTAF: '' }) as { reason: string }).reason, 'missing raw TAF text');
});

Deno.test('parseAwcTaf: keys match what ingest_tafs() reads', () => {
	const r = parseAwcTaf(awcTaf);
	assert.ok(r.ok);
	assert.deepEqual(Object.keys(r.record).sort(), ['issued_at', 'periods', 'raw_text', 'station', 'valid_from', 'valid_to']);
	assert.deepEqual(Object.keys(r.record.periods[0]).sort(), [
		'change_type', 'layers', 'probability', 'sky_clear_code', 'time_from', 'time_to', 'visibility_is_min',
		'visibility_sm', 'wx_string'
	]);
});
