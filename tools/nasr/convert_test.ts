import assert from 'node:assert/strict';
import { buildAirways, buildNavFixes, parseCsv, requireColumns, toCsv } from './convert.ts';

const read = (f: string) => parseCsv(Deno.readTextFileSync(new URL(`./testdata/${f}`, import.meta.url)));

Deno.test('parseCsv: quotes, doubled quotes, CRLF', () => {
	assert.deepEqual(parseCsv('A,B\r\n"x, y","say ""hi"""\r\n'), [{ A: 'x, y', B: 'say "hi"' }]);
});

Deno.test('requireColumns explains a format change', () => {
	assert.throws(() => requireColumns('FIX_BASE.csv', [{ FIX: 'X' }], ['FIX_ID']), /missing column\(s\) FIX_ID\. Found: FIX/);
});

Deno.test('nav fixes from fixes, navaids and airports; bad rows dropped', () => {
	const fixes = buildNavFixes(read('FIX_BASE.csv'), read('NAV_BASE.csv'), read('APT_BASE.csv'));
	assert.equal(fixes.length, 7); // 2 fixes (BAD has no position), 3 navaids, 2 airports
	assert.deepEqual(fixes.find((f) => f.ident === 'BFI'), {
		ident: 'BFI', kind: 'airport', icao_ident: 'KBFI', name: 'BOEING FIELD/KING COUNTY INTL',
		lat: 47.53, lon: -122.302, state_code: 'WA', country_code: 'US'
	});
	assert.equal(fixes.find((f) => f.ident === 'SEA' && f.kind === 'navaid')?.name, 'SEATTLE VORTAC');
});

Deno.test('airways: order, nearest candidate for duplicates, separate pieces', () => {
	const fixes = buildNavFixes(read('FIX_BASE.csv'), read('NAV_BASE.csv'), read('APT_BASE.csv'));
	const { rows, missing } = buildAirways(read('AWY_BASE.csv'), fixes);
	const j1 = rows.filter((r) => r.airway_id === 'J1');
	assert.deepEqual(j1.map((r) => [r.seq, r.ident]), [[10, 'SEA'], [20, 'OLM'], [30, 'BTG']]);
	assert.equal(j1[1].lon, -122.9027, 'OLM on J1 is the Washington navaid, not the Florida fix');
	assert.deepEqual(rows.filter((r) => r.airway_id === 'V23').map((r) => r.ident), ['BTG', 'OLM', 'SUMMA', 'SEA']);
	assert.deepEqual(missing.sort(), ['J1:NOPE1', 'J1:NOPE2'], 'second J1 piece listed as missing, not merged');
});

Deno.test('toCsv quotes when needed', () => {
	assert.equal(toCsv([{ a: 'x,y', b: 1 }], ['a', 'b']), 'a,b\n"x,y",1\n');
});
