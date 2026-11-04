import assert from 'node:assert/strict';
import { flightCategory, parseAwcMetar, parseSky, parseVisibility } from './metar.ts';

Deno.test('parseSky: layers sorted, heights in feet, remarks ignored', () => {
	const s = parseSky('KSEA 041853Z 18008KT 10SM BKN060 FEW020 OVC250 12/08 A3001 RMK AO2 SLP165 BKN010');
	assert.deepEqual(s.layers, [
		{ cover: 'FEW', base_agl_ft: 2000, cloud_type: null },
		{ cover: 'BKN', base_agl_ft: 6000, cloud_type: null },
		{ cover: 'OVC', base_agl_ft: 25000, cloud_type: null }
	]);
	assert.equal(s.is_auto, false);
	assert.equal(s.sky_clear_code, null);
});

Deno.test('parseSky: AUTO + CLR', () => {
	const s = parseSky('KRNT 041853Z AUTO 00000KT 10SM CLR 11/07 A3002 RMK AO2');
	assert.equal(s.is_auto, true);
	assert.equal(s.sky_clear_code, 'CLR');
	assert.equal(s.layers.length, 0);
});

Deno.test('parseSky: vertical visibility in fog', () => {
	const s = parseSky('KSFO 041856Z 28005KT 1/4SM FG VV002 11/11 A2995');
	assert.deepEqual(s.layers, [{ cover: 'VV', base_agl_ft: 200, cloud_type: null }]);
});

Deno.test('parseSky: CB and TCU', () => {
	const s = parseSky('KMIA 041853Z 09012G22KT 6SM TSRA SCT025CB BKN040TCU OVC100 27/24 A2990');
	assert.deepEqual(
		s.layers.map((l) => [l.cover, l.cloud_type]),
		[['SCT', 'CB'], ['BKN', 'TCU'], ['OVC', null]]
	);
});

Deno.test('parseSky: unknown heights counted, not stored; /// type ignored', () => {
	const s = parseSky('EGPH 041850Z AUTO 25010KT 9999 BKN///  SCT040/// 09/05 Q1008');
	assert.equal(s.unknown_height_layers, 1);
	assert.deepEqual(s.layers, [{ cover: 'SCT', base_agl_ft: 4000, cloud_type: null }]);
});

Deno.test('parseSky: international clear codes; trend groups ignored', () => {
	assert.equal(parseSky('EGLL 041850Z AUTO 24012KT 9999 NCD 13/07 Q1012').sky_clear_code, 'NCD');
	assert.equal(parseSky('LFPG 041830Z 22008KT CAVOK 14/06 Q1015 NOSIG').sky_clear_code, 'CAVOK');
	const s = parseSky('EHAM 041825Z 23015KT 9999 FEW030 12/07 Q1010 TEMPO BKN012');
	assert.deepEqual(s.layers.map((l) => l.cover), ['FEW']);
});

Deno.test('parseVisibility', () => {
	assert.deepEqual(parseVisibility('10+'), { sm: 10, isMin: true });
	assert.deepEqual(parseVisibility('P6SM'), { sm: 6, isMin: true });
	assert.deepEqual(parseVisibility('1 1/2'), { sm: 1.5, isMin: false });
	assert.deepEqual(parseVisibility('1/4'), { sm: 0.25, isMin: false });
	assert.deepEqual(parseVisibility(3), { sm: 3, isMin: false });
	assert.deepEqual(parseVisibility(undefined), { sm: null, isMin: false });
});

Deno.test('flightCategory', () => {
	const L = (cover: 'BKN' | 'SCT' | 'OVC', ft: number) => [{ cover, base_agl_ft: ft, cloud_type: null }];
	assert.equal(flightCategory(L('BKN', 6000), 10), 'VFR');
	assert.equal(flightCategory(L('SCT', 800), 10), 'VFR'); // SCT is not a ceiling
	assert.equal(flightCategory(L('OVC', 3000), 10), 'MVFR');
	assert.equal(flightCategory(L('OVC', 900), 10), 'IFR');
	assert.equal(flightCategory(L('OVC', 400), 10), 'LIFR');
	assert.equal(flightCategory([], 0.5), 'LIFR');
	assert.equal(flightCategory([], null), null);
});

// Shape of one object from https://aviationweather.gov/api/data/metar?format=json
const awc = {
	icaoId: 'KBFI',
	receiptTime: '2026-11-04T18:56:21.000Z',
	obsTime: 1793818380, // 2026-11-04T18:53:00Z
	reportTime: '2026-11-04T19:00:00.000Z',
	temp: 12.2,
	dewp: 8.3,
	wdir: 170,
	wspd: 6,
	wgst: null,
	visib: '10+',
	altim: 1016.3,
	wxString: null,
	metarType: 'METAR',
	rawOb: 'KBFI 041853Z 17006KT 10SM FEW025 BKN060 OVC090 12/08 A3001 RMK AO2 SLP164 T01220083',
	lat: 47.5299,
	lon: -122.3019,
	elev: 6,
	name: 'Seattle/Boeing Fld, WA, US',
	cover: 'OVC',
	clouds: [
		{ cover: 'FEW', base: 2500 },
		{ cover: 'BKN', base: 6000 },
		{ cover: 'OVC', base: 9000 }
	],
	fltCat: 'VFR'
};

Deno.test('parseAwcMetar: full record', () => {
	const r = parseAwcMetar(awc);
	assert.ok(r.ok);
	assert.deepEqual(r.record.station, {
		icao: 'KBFI',
		name: 'Seattle/Boeing Fld, WA, US',
		lat: 47.5299,
		lon: -122.3019,
		elevation_ft: 20
	});
	assert.equal(r.record.observed_at, '2026-11-04T18:53:00.000Z');
	assert.equal(r.record.visibility_sm, 10);
	assert.equal(r.record.visibility_is_min, true);
	assert.equal(r.record.flight_category, 'VFR');
	assert.equal(r.record.layers.length, 3);
	assert.equal(r.record.layers[1].base_agl_ft, 6000);
});

Deno.test('parseAwcMetar: record keys match what ingest_metars() reads', () => {
	const r = parseAwcMetar(awc);
	assert.ok(r.ok);
	assert.deepEqual(Object.keys(r.record).sort(), [
		'altimeter_hpa', 'dewpoint_c', 'flight_category', 'is_auto', 'layers', 'observed_at', 'raw_text',
		'report_type', 'sky_clear_code', 'station', 'temp_c', 'visibility_is_min', 'visibility_sm', 'wind_dir_deg',
		'wind_gust_kt', 'wind_speed_kt', 'wind_variable', 'wx_string'
	]);
});

Deno.test('parseAwcMetar: VRB wind, SPECI, reportTime fallback, computed category', () => {
	const r = parseAwcMetar({
		...awc,
		obsTime: undefined,
		reportTime: '2026-11-04 19:12:00',
		metarType: undefined,
		wdir: 'VRB',
		fltCat: undefined,
		rawOb: 'SPECI KBFI 041912Z VRB03KT 2SM BR OVC008 11/10 A3001'
	});
	assert.ok(r.ok);
	assert.equal(r.record.observed_at, '2026-11-04T19:12:00.000Z');
	assert.equal(r.record.report_type, 'SPECI');
	assert.equal(r.record.wind_dir_deg, null);
	assert.equal(r.record.wind_variable, true);
	assert.equal(r.record.flight_category, 'IFR');
});

Deno.test('parseAwcMetar: rejects incomplete records with a reason', () => {
	assert.deepEqual(parseAwcMetar({ ...awc, elev: null }), {
		ok: false,
		station: 'KBFI',
		reason: 'missing station elevation'
	});
	assert.equal((parseAwcMetar({ ...awc, rawOb: '' }) as { reason: string }).reason, 'missing raw report text');
	assert.equal((parseAwcMetar(null) as { station: string }).station, '?');
});
