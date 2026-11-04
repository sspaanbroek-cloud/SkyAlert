// Convert the FAA NASR 28-day subscription CSV files into the two files
// SkyAlert loads: nav_fix.csv and airway_fix.csv.
//
//   deno run --allow-read --allow-write tools/nasr/convert.ts <CSV_Data dir> <out dir> [cycle YYYY-MM-DD]
//
// Source: https://www.faa.gov/air_traffic/flight_info/aeronav/aero_data/NASR_Subscription/
// (the "CSV" download). Files and columns used:
//   FIX_BASE.csv  FIX_ID, STATE_CODE, COUNTRY_CODE, LAT_DECIMAL, LONG_DECIMAL
//   NAV_BASE.csv  NAV_ID, NAV_TYPE, NAME, STATE_CODE, COUNTRY_CODE, LAT_DECIMAL, LONG_DECIMAL
//   APT_BASE.csv  ARPT_ID, ICAO_ID, ARPT_NAME, STATE_CODE, COUNTRY_CODE, LAT_DECIMAL, LONG_DECIMAL
//   AWY_BASE.csv  AWY_ID, AWY_LOCATION, AIRWAY_STRING (fixes in order, space separated)
// If FAA renames a column, the script stops and lists the columns it found.

export type Row = Record<string, string>;

/** Minimal RFC 4180 CSV parser (quoted fields, doubled quotes, CRLF). */
export function parseCsv(text: string): Row[] {
	const rows: string[][] = [];
	let row: string[] = [];
	let field = '';
	let quoted = false;
	for (let i = 0; i < text.length; i++) {
		const ch = text[i];
		if (quoted) {
			if (ch === '"' && text[i + 1] === '"') {
				field += '"';
				i++;
			} else if (ch === '"') quoted = false;
			else field += ch;
		} else if (ch === '"') quoted = true;
		else if (ch === ',') {
			row.push(field);
			field = '';
		} else if (ch === '\n' || ch === '\r') {
			if (ch === '\r' && text[i + 1] === '\n') i++;
			row.push(field);
			rows.push(row);
			row = [];
			field = '';
		} else field += ch;
	}
	if (field !== '' || row.length) {
		row.push(field);
		rows.push(row);
	}
	const [header, ...data] = rows.filter((r) => r.length > 1 || r[0] !== '');
	if (!header) return [];
	const keys = header.map((h) => h.trim().replace(/^﻿/, ''));
	return data.map((r) => Object.fromEntries(keys.map((k, i) => [k, (r[i] ?? '').trim()])));
}

export function requireColumns(file: string, rows: Row[], cols: string[]) {
	if (rows.length === 0) throw new Error(`${file}: no data rows`);
	const have = Object.keys(rows[0]);
	const missing = cols.filter((c) => !have.includes(c));
	if (missing.length) {
		throw new Error(`${file}: missing column(s) ${missing.join(', ')}. Found: ${have.join(', ')}`);
	}
}

export interface NavFix {
	ident: string;
	kind: 'fix' | 'navaid' | 'airport';
	icao_ident: string;
	name: string;
	lat: number;
	lon: number;
	state_code: string;
	country_code: string;
}

export interface AirwayFix {
	airway_id: string;
	seq: number;
	ident: string;
	lat: number;
	lon: number;
}

const coord = (r: Row) => ({ lat: Number(r.LAT_DECIMAL), lon: Number(r.LONG_DECIMAL) });
const valid = (p: { lat: number; lon: number }) =>
	Number.isFinite(p.lat) && Number.isFinite(p.lon) && Math.abs(p.lat) <= 90 && Math.abs(p.lon) <= 180 && !(p.lat === 0 && p.lon === 0);

export function buildNavFixes(fix: Row[], nav: Row[], apt: Row[]): NavFix[] {
	const out: NavFix[] = [];
	for (const r of fix) {
		const p = coord(r);
		if (r.FIX_ID && valid(p)) out.push({ ident: r.FIX_ID, kind: 'fix', icao_ident: '', name: '', ...p, state_code: r.STATE_CODE ?? '', country_code: r.COUNTRY_CODE ?? '' });
	}
	for (const r of nav) {
		const p = coord(r);
		if (r.NAV_ID && valid(p)) out.push({ ident: r.NAV_ID, kind: 'navaid', icao_ident: '', name: [r.NAME, r.NAV_TYPE].filter(Boolean).join(' '), ...p, state_code: r.STATE_CODE ?? '', country_code: r.COUNTRY_CODE ?? '' });
	}
	for (const r of apt) {
		const p = coord(r);
		if (r.ARPT_ID && valid(p)) out.push({ ident: r.ARPT_ID, kind: 'airport', icao_ident: r.ICAO_ID ?? '', name: r.ARPT_NAME ?? '', ...p, state_code: r.STATE_CODE ?? '', country_code: r.COUNTRY_CODE ?? '' });
	}
	return out;
}

const distSq = (a: { lat: number; lon: number }, b: { lat: number; lon: number }) => {
	const dx = (a.lon - b.lon) * Math.cos(((a.lat + b.lat) / 2) * (Math.PI / 180));
	const dy = a.lat - b.lat;
	return dx * dx + dy * dy;
};

/**
 * Airways: each AIRWAY_STRING is a list of fix/navaid idents in order. An
 * ident with several candidates resolves to the one nearest its neighbour.
 * The same AWY_ID can exist in several regions (AWY_LOCATION); each piece
 * gets its own seq range (100,000 apart) so they never join up.
 */
export function buildAirways(awy: Row[], fixes: NavFix[]): { rows: AirwayFix[]; missing: string[] } {
	const byIdent = new Map<string, NavFix[]>();
	for (const f of fixes) if (f.kind !== 'airport') byIdent.set(f.ident, [...(byIdent.get(f.ident) ?? []), f]);
	const rows: AirwayFix[] = [];
	const missing = new Set<string>();
	const pieces = new Map<string, number>();
	for (const r of awy) {
		const id = r.AWY_ID?.replace(/\s+/g, '');
		const idents = (r.AIRWAY_STRING ?? '').split(/\s+/).filter(Boolean);
		if (!id || idents.length < 2) continue;
		const piece = pieces.get(id) ?? 0;
		pieces.set(id, piece + 1);
		let prev: NavFix | undefined;
		idents.forEach((ident, i) => {
			const cands = byIdent.get(ident);
			if (!cands?.length) {
				missing.add(`${id}:${ident}`);
				return;
			}
			let pick = cands[0];
			if (cands.length > 1) {
				const ref = prev ?? byIdent.get(idents[i + 1] ?? '')?.[0];
				if (ref) pick = cands.reduce((best, c) => (distSq(c, ref) < distSq(best, ref) ? c : best));
			}
			rows.push({ airway_id: id, seq: piece * 100_000 + (i + 1) * 10, ident, lat: pick.lat, lon: pick.lon });
			prev = pick;
		});
	}
	return { rows, missing: [...missing] };
}

const csvField = (v: string | number) => {
	const s = String(v);
	return /[",\n\r]/.test(s) ? `"${s.replace(/"/g, '""')}"` : s;
};
export const toCsv = (rows: Record<string, string | number>[], cols: string[]) =>
	[cols.join(','), ...rows.map((r) => cols.map((c) => csvField(r[c] ?? '')).join(','))].join('\n') + '\n';

if (import.meta.main) {
	const [inDir, outDir, cycle = new Date().toISOString().slice(0, 10)] = Deno.args;
	if (!inDir || !outDir) {
		console.error('usage: convert.ts <NASR CSV_Data dir> <out dir> [cycle YYYY-MM-DD]');
		Deno.exit(2);
	}
	const read = (f: string) => parseCsv(Deno.readTextFileSync(`${inDir}/${f}`));
	const fix = read('FIX_BASE.csv');
	const nav = read('NAV_BASE.csv');
	const apt = read('APT_BASE.csv');
	const awy = read('AWY_BASE.csv');
	requireColumns('FIX_BASE.csv', fix, ['FIX_ID', 'LAT_DECIMAL', 'LONG_DECIMAL']);
	requireColumns('NAV_BASE.csv', nav, ['NAV_ID', 'NAV_TYPE', 'LAT_DECIMAL', 'LONG_DECIMAL']);
	requireColumns('APT_BASE.csv', apt, ['ARPT_ID', 'ICAO_ID', 'LAT_DECIMAL', 'LONG_DECIMAL']);
	requireColumns('AWY_BASE.csv', awy, ['AWY_ID', 'AIRWAY_STRING']);

	const fixes = buildNavFixes(fix, nav, apt);
	const { rows, missing } = buildAirways(awy, fixes);
	Deno.mkdirSync(outDir, { recursive: true });
	Deno.writeTextFileSync(`${outDir}/nav_fix.csv`, toCsv(fixes.map((f) => ({ ...f, cycle })) as never,
		['ident', 'kind', 'icao_ident', 'name', 'lat', 'lon', 'state_code', 'country_code', 'cycle']));
	Deno.writeTextFileSync(`${outDir}/airway_fix.csv`, toCsv(rows as never, ['airway_id', 'seq', 'ident', 'lat', 'lon']));
	console.log(JSON.stringify({
		cycle,
		fixes: fixes.filter((f) => f.kind === 'fix').length,
		navaids: fixes.filter((f) => f.kind === 'navaid').length,
		airports: fixes.filter((f) => f.kind === 'airport').length,
		airway_points: rows.length,
		airway_idents_not_found: missing.length,
		examples_not_found: missing.slice(0, 10)
	}));
}
