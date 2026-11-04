// METAR parsing for the ingest worker. Pure functions, no Deno/Node APIs, so
// the same code is testable anywhere.
//
// Cloud layers are read from the raw report text, which is the source of
// truth and the only place CB/TCU appear. Numeric fields come from the
// Aviation Weather Center (AWC) JSON, which has already decoded them.

export type Cover = 'FEW' | 'SCT' | 'BKN' | 'OVC' | 'VV';
export type SkyClear = 'CLR' | 'SKC' | 'NSC' | 'NCD' | 'CAVOK';
export type FlightCategory = 'VFR' | 'MVFR' | 'IFR' | 'LIFR';

export interface CloudLayer {
	cover: Cover;
	base_agl_ft: number;
	cloud_type: 'CB' | 'TCU' | null;
}

export interface ParsedSky {
	layers: CloudLayer[];
	sky_clear_code: SkyClear | null;
	is_auto: boolean;
	/** Layers reported with an unknown height ("BKN///"), which can't be stored. */
	unknown_height_layers: number;
}

/** Shape sent to public.ingest_metars(). Keep in sync with that function. */
export interface IngestRecord {
	station: { icao: string; name: string | null; lat: number; lon: number; elevation_ft: number };
	observed_at: string;
	raw_text: string;
	report_type: 'METAR' | 'SPECI';
	is_auto: boolean;
	visibility_sm: number | null;
	visibility_is_min: boolean;
	flight_category: FlightCategory | null;
	wind_dir_deg: number | null;
	wind_variable: boolean;
	wind_speed_kt: number | null;
	wind_gust_kt: number | null;
	temp_c: number | null;
	dewpoint_c: number | null;
	altimeter_hpa: number | null;
	wx_string: string | null;
	sky_clear_code: SkyClear | null;
	layers: CloudLayer[];
}

const LAYER_RE = /^(FEW|SCT|BKN|OVC|VV)(\d{3}|\/{3})(CB|TCU|\/{3})?$/;
const SKY_CLEAR = new Set(['CLR', 'SKC', 'NSC', 'NCD', 'CAVOK']);
// Everything after these is remarks or a forecast trend, not the observation.
const STOP_TOKENS = new Set(['RMK', 'TEMPO', 'BECMG', 'NOSIG']);

const M_TO_FT = 3.28084;

/** Read sky condition from the body of a raw METAR/SPECI. */
export function parseSky(raw: string): ParsedSky {
	const out: ParsedSky = { layers: [], sky_clear_code: null, is_auto: false, unknown_height_layers: 0 };
	for (const token of raw.trim().split(/\s+/)) {
		if (STOP_TOKENS.has(token)) break;
		if (token === 'AUTO') {
			out.is_auto = true;
			continue;
		}
		if (SKY_CLEAR.has(token)) {
			out.sky_clear_code = token as SkyClear;
			continue;
		}
		const m = LAYER_RE.exec(token);
		if (!m) continue;
		if (m[2] === '///') {
			out.unknown_height_layers++;
			continue;
		}
		out.layers.push({
			cover: m[1] as Cover,
			base_agl_ft: Number(m[2]) * 100,
			cloud_type: m[3] === 'CB' || m[3] === 'TCU' ? m[3] : null
		});
	}
	out.layers.sort((a, b) => a.base_agl_ft - b.base_agl_ft);
	return out;
}

/** FAA flight category from ceiling (lowest BKN/OVC/VV) and visibility. */
export function flightCategory(layers: CloudLayer[], visibilitySm: number | null): FlightCategory | null {
	const ceiling = layers.find((l) => l.cover === 'BKN' || l.cover === 'OVC' || l.cover === 'VV')?.base_agl_ft;
	if (ceiling === undefined && visibilitySm === null) return null;
	const c = ceiling ?? Infinity;
	const v = visibilitySm ?? Infinity;
	if (c < 500 || v < 1) return 'LIFR';
	if (c < 1000 || v < 3) return 'IFR';
	if (c <= 3000 || v <= 5) return 'MVFR';
	return 'VFR';
}

/** AWC visibility: number, or strings such as "10+", "6+", "1/2", "1 1/2". */
export function parseVisibility(v: unknown): { sm: number | null; isMin: boolean } {
	if (typeof v === 'number' && Number.isFinite(v)) return { sm: v, isMin: false };
	if (typeof v !== 'string') return { sm: null, isMin: false };
	const s = v.trim().replace(/SM$/i, '');
	const isMin = s.endsWith('+') || s.startsWith('P');
	const core = s.replace(/\+$/, '').replace(/^P/, '');
	const m = /^(?:(\d+)\s+)?(\d+)\/(\d+)$/.exec(core);
	if (m) {
		const whole = m[1] ? Number(m[1]) : 0;
		return { sm: whole + Number(m[2]) / Number(m[3]), isMin };
	}
	const n = Number(core);
	return { sm: core !== '' && Number.isFinite(n) ? n : null, isMin };
}

const num = (v: unknown): number | null => {
	if (typeof v === 'number') return Number.isFinite(v) ? v : null;
	if (typeof v === 'string' && v.trim() !== '' && Number.isFinite(Number(v))) return Number(v);
	return null;
};

function observedAt(o: Record<string, unknown>): string | null {
	const t = num(o.obsTime);
	if (t !== null) return new Date(t * 1000).toISOString();
	if (typeof o.reportTime === 'string') {
		const s = o.reportTime.trim().replace(' ', 'T');
		const d = new Date(/[zZ]|[+-]\d\d:?\d\d$/.test(s) ? s : `${s}Z`);
		if (!Number.isNaN(d.getTime())) return d.toISOString();
	}
	return null;
}

export type ParseResult = { ok: true; record: IngestRecord } | { ok: false; station: string; reason: string };

/** Turn one AWC JSON METAR into an ingest record, or explain why not. */
export function parseAwcMetar(input: unknown): ParseResult {
	const o = (input ?? {}) as Record<string, unknown>;
	const icao = typeof o.icaoId === 'string' ? o.icaoId.trim().toUpperCase() : '';
	const fail = (reason: string): ParseResult => ({ ok: false, station: icao || '?', reason });

	if (!/^[A-Z0-9]{3,4}$/.test(icao)) return fail('missing or invalid station id');
	const raw = typeof o.rawOb === 'string' ? o.rawOb.trim() : '';
	if (!raw) return fail('missing raw report text');
	const lat = num(o.lat);
	const lon = num(o.lon);
	if (lat === null || lon === null || Math.abs(lat) > 90 || Math.abs(lon) > 180) return fail('missing station position');
	const elevM = num(o.elev);
	if (elevM === null) return fail('missing station elevation');
	const when = observedAt(o);
	if (!when) return fail('missing observation time');

	const sky = parseSky(raw);
	const vis = parseVisibility(o.visib);
	const fltCat = typeof o.fltCat === 'string' && /^(VFR|MVFR|IFR|LIFR)$/.test(o.fltCat) ? (o.fltCat as FlightCategory) : null;
	const reportType =
		o.metarType === 'SPECI' || /^SPECI\b/.test(raw) ? 'SPECI' : 'METAR';
	const variable = o.wdir === 'VRB';

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
			observed_at: when,
			raw_text: raw,
			report_type: reportType,
			is_auto: sky.is_auto,
			visibility_sm: vis.sm,
			visibility_is_min: vis.isMin,
			flight_category: fltCat ?? flightCategory(sky.layers, vis.sm),
			wind_dir_deg: variable ? null : num(o.wdir),
			wind_variable: variable,
			wind_speed_kt: num(o.wspd),
			wind_gust_kt: num(o.wgst),
			temp_c: num(o.temp),
			dewpoint_c: num(o.dewp),
			altimeter_hpa: num(o.altim),
			wx_string: typeof o.wxString === 'string' && o.wxString.trim() ? o.wxString.trim() : null,
			sky_clear_code: sky.sky_clear_code,
			layers: sky.layers
		}
	};
}
