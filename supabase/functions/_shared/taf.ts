// TAF parsing for the ingest worker (AWC JSON -> ingest_tafs() payload).
//
// AWC decodes each TAF into `fcsts`, one per change group, with fcstChange
// null for the base forecast and "FM" / "BECMG" / "TEMPO" / "PROB" otherwise.
// Cloud groups come as {cover, base (ft AGL), type}; CLR/SKC/NSC/CAVOK may
// appear as a cover with no base.

import { type CloudLayer, type SkyClear, parseVisibility } from './metar.ts';

export interface TafPeriod {
	change_type: 'BASE' | 'FM' | 'BECMG' | 'TEMPO' | 'PROB';
	probability: number | null;
	time_from: string;
	time_to: string | null;
	visibility_sm: number | null;
	visibility_is_min: boolean;
	wx_string: string | null;
	sky_clear_code: SkyClear | null;
	/** null: this group doesn't change the cloud (only meaningful for BECMG/TEMPO/PROB). */
	layers: CloudLayer[] | null;
}

/** Shape sent to public.ingest_tafs(). Keep in sync with that function. */
export interface TafRecord {
	station: { icao: string; name: string | null; lat: number; lon: number; elevation_ft: number };
	issued_at: string;
	valid_from: string;
	valid_to: string;
	raw_text: string;
	periods: TafPeriod[];
}

const COVERS = new Set(['FEW', 'SCT', 'BKN', 'OVC', 'VV']);
const CLEARS = new Set(['CLR', 'SKC', 'NSC', 'NCD', 'CAVOK']);
const M_TO_FT = 3.28084;

const num = (v: unknown): number | null => {
	if (typeof v === 'number') return Number.isFinite(v) ? v : null;
	if (typeof v === 'string' && v.trim() !== '' && Number.isFinite(Number(v))) return Number(v);
	return null;
};

function isoFrom(v: unknown): string | null {
	const n = num(v);
	if (n !== null) return new Date(n * 1000).toISOString();
	if (typeof v === 'string' && v.trim()) {
		const s = v.trim().replace(' ', 'T');
		const d = new Date(/[zZ]|[+-]\d\d:?\d\d$/.test(s) ? s : `${s}Z`);
		if (!Number.isNaN(d.getTime())) return d.toISOString();
	}
	return null;
}

function changeType(f: Record<string, unknown>, index: number): TafPeriod['change_type'] | null {
	const c = typeof f.fcstChange === 'string' ? f.fcstChange.trim().toUpperCase() : '';
	if (!c) return index === 0 ? 'BASE' : 'FM';
	if (c === 'FM' || c === 'BECMG' || c === 'TEMPO') return c;
	if (c.startsWith('PROB')) return 'PROB';
	return null;
}

export type TafParseResult = { ok: true; record: TafRecord } | { ok: false; station: string; reason: string };

export function parseAwcTaf(input: unknown): TafParseResult {
	const o = (input ?? {}) as Record<string, unknown>;
	const icao = typeof o.icaoId === 'string' ? o.icaoId.trim().toUpperCase() : '';
	const fail = (reason: string): TafParseResult => ({ ok: false, station: icao || '?', reason });
	if (!/^[A-Z0-9]{3,4}$/.test(icao)) return fail('missing or invalid station id');
	const raw = typeof o.rawTAF === 'string' ? o.rawTAF.trim() : '';
	if (!raw) return fail('missing raw TAF text');
	const lat = num(o.lat);
	const lon = num(o.lon);
	const elevM = num(o.elev);
	if (lat === null || lon === null) return fail('missing station position');
	if (elevM === null) return fail('missing station elevation');
	const issued = isoFrom(o.issueTime);
	const validFrom = isoFrom(o.validTimeFrom);
	const validTo = isoFrom(o.validTimeTo);
	if (!issued || !validFrom || !validTo) return fail('missing issue or validity time');
	if (!Array.isArray(o.fcsts) || o.fcsts.length === 0) return fail('no forecast periods');

	const periods: TafPeriod[] = [];
	o.fcsts.forEach((item, i) => {
		const f = (item ?? {}) as Record<string, unknown>;
		const type = changeType(f, i);
		const from = isoFrom(f.timeFrom);
		if (!type || !from) return; // unknown group: skip it rather than the whole TAF
		const vis = parseVisibility(f.visib);

		let layers: CloudLayer[] | null = null;
		let skyClear: SkyClear | null = null;
		if (Array.isArray(f.clouds)) {
			layers = [];
			for (const c of f.clouds as Record<string, unknown>[]) {
				const cover = typeof c?.cover === 'string' ? c.cover.toUpperCase() : '';
				if (CLEARS.has(cover)) {
					skyClear = cover as SkyClear;
					continue;
				}
				const base = num(c?.base);
				if (!COVERS.has(cover) || base === null) continue;
				const t = typeof c?.type === 'string' ? c.type.toUpperCase() : null;
				layers.push({ cover: cover as CloudLayer['cover'], base_agl_ft: base, cloud_type: t === 'CB' || t === 'TCU' ? t : null });
			}
			if (layers.length === 0 && !skyClear) layers = null; // empty list: no cloud information
		}
		const vv = num(f.vertVis);
		if (vv !== null) (layers ??= []).push({ cover: 'VV', base_agl_ft: vv, cloud_type: null });
		layers?.sort((a, b) => a.base_agl_ft - b.base_agl_ft);
		if (skyClear && !layers) layers = [];

		periods.push({
			change_type: type,
			probability: num(f.probability),
			time_from: from,
			time_to: isoFrom(f.timeTo),
			visibility_sm: vis.sm,
			visibility_is_min: vis.isMin,
			wx_string: typeof f.wxString === 'string' && f.wxString.trim() ? f.wxString.trim() : null,
			sky_clear_code: skyClear,
			layers
		});
	});
	if (periods.length === 0) return fail('no usable forecast periods');

	return {
		ok: true,
		record: {
			station: {
				icao,
				name: typeof o.name === 'string' && o.name.trim() ? o.name.trim() : null,
				lat,
				lon,
				elevation_ft: Math.round(elevM * M_TO_FT)
			},
			issued_at: issued,
			valid_from: validFrom,
			valid_to: validTo,
			raw_text: raw,
			periods
		}
	};
}
