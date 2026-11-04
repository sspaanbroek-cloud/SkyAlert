import { supabase } from './supabase';
import { compass } from './weather';

export type Rating = 'clear' | 'partial' | 'hidden' | 'unknown';

export interface Assessment {
	rating: Rating;
	explanation: string;
	high_cloud_caveat: boolean;
	metar_station: string | null;
	obs_age_min: number | null;
	stations_used: string[];
	computed_at: string;
}

export interface Pass {
	id: number;
	basis: 'live_adsb' | 'filed_plan' | 'recurring';
	callsign: string | null;
	icao24: string | null;
	aircraft_type: string | null;
	closest_approach_at: string;
	closest_distance_nm: number;
	altitude_ft: number | null;
	azimuth_deg: number | null;
	elevation_deg: number | null;
	confidence: number | null;
	computed_at: string;
	assessment: Assessment | null;
}

const COLUMNS =
	'id, basis, callsign, icao24, aircraft_type, closest_approach_at, closest_distance_nm, altitude_ft, azimuth_deg, elevation_deg, confidence, computed_at, ' +
	'visibility_assessment(rating, explanation, high_cloud_caveat, metar_station, obs_age_min, stations_used, computed_at)';

/** Passes from 2 minutes ago onwards, soonest first. RLS limits this to your own spots. */
export async function listUpcomingPasses(spotId: string, now = new Date()): Promise<Pass[]> {
	const since = new Date(now.getTime() - 2 * 60_000).toISOString();
	const { data, error } = await supabase
		.from('overflight_prediction')
		.select(COLUMNS)
		.eq('spot_id', spotId)
		.gte('closest_approach_at', since)
		.order('closest_approach_at')
		.limit(20);
	if (error) throw error;
	const rows = (data ?? []) as unknown as (Record<string, unknown> & { visibility_assessment: unknown })[];
	return rows.map(({ visibility_assessment: va, ...p }) => ({
		...p,
		// one-to-one embed: PostgREST returns an object, older versions an array
		assessment: (Array.isArray(va) ? (va[0] ?? null) : (va ?? null)) as Assessment | null,
		closest_distance_nm: Number(p.closest_distance_nm),
		azimuth_deg: p.azimuth_deg == null ? null : Number(p.azimuth_deg),
		elevation_deg: p.elevation_deg == null ? null : Number(p.elevation_deg),
		confidence: p.confidence == null ? null : Number(p.confidence)
	})) as Pass[];
}

export function whenLabel(atIso: string, now: Date): string {
	const s = Math.round((new Date(atIso).getTime() - now.getTime()) / 1000);
	if (s < -60) return 'Just passed';
	if (s <= 60) return 'Passing now';
	const m = Math.round(s / 60);
	if (m < 60) return `in ${m} min`;
	const h = Math.floor(m / 60);
	return `in ${h} h ${m % 60} min`;
}

export function clockTime(atIso: string, timeZone?: string): string {
	return new Date(atIso)
		.toLocaleTimeString('en-US', { hour: 'numeric', minute: '2-digit', timeZone })
		.replace(' AM', ' am')
		.replace(' PM', ' pm');
}

export function lookLabel(p: Pick<Pass, 'azimuth_deg' | 'elevation_deg'>): string | null {
	if (p.elevation_deg == null) return null;
	if (p.elevation_deg >= 80) return 'Straight overhead';
	const up = `${Math.round(p.elevation_deg)}° above the horizon`;
	if (p.azimuth_deg == null) return up;
	return `Look ${compass(p.azimuth_deg)} (${Math.round(p.azimuth_deg)}°), ${up}`;
}

export function confidenceLabel(c: number | null): 'High' | 'Medium' | 'Low' | null {
	if (c == null) return null;
	return c >= 0.75 ? 'High' : c >= 0.5 ? 'Medium' : 'Low';
}

export const flightLabel = (p: Pick<Pass, 'callsign' | 'icao24'>) => p.callsign ?? p.icao24?.toUpperCase() ?? 'Unknown aircraft';

export const RATING_LABEL: Record<Rating, string> = {
	clear: 'Clear view',
	partial: 'Partly visible',
	hidden: 'Hidden by cloud',
	unknown: 'Visibility unknown'
};

/** Local calendar date (YYYY-MM-DD) of an instant in a time zone. */
function localDate(d: Date, timeZone?: string): string {
	return d.toLocaleDateString('en-CA', { timeZone, year: 'numeric', month: '2-digit', day: '2-digit' });
}

/** "" for today, "tomorrow", or a weekday such as "Thu", in the spot's time zone. */
export function dayLabel(atIso: string, now: Date, timeZone?: string): string {
	const at = new Date(atIso);
	const day = localDate(at, timeZone);
	if (day === localDate(now, timeZone)) return '';
	if (day === localDate(new Date(now.getTime() + 86_400_000), timeZone)) return 'tomorrow';
	return at.toLocaleDateString('en-US', { weekday: 'short', timeZone });
}

/** "ASA123, 33,000 ft, passes at 7:42 pm." (or "passes tomorrow at ...") */
export function headline(
	p: Pick<Pass, 'callsign' | 'icao24' | 'altitude_ft' | 'closest_approach_at'>,
	timeZone?: string,
	now = new Date()
) {
	const alt = p.altitude_ft != null ? `${Math.round(p.altitude_ft).toLocaleString('en-US')} ft, ` : '';
	const day = dayLabel(p.closest_approach_at, now, timeZone);
	return `${flightLabel(p)}, ${alt}passes ${day ? `${day} ` : ''}at ${clockTime(p.closest_approach_at, timeZone)}.`;
}

export const BASIS_LABEL: Record<Pass['basis'], string> = {
	live_adsb: 'Live tracking',
	recurring: 'Usual flight',
	filed_plan: 'Filed flight plan'
};

export function weatherSource(a: Pick<Assessment, 'metar_station' | 'obs_age_min'>): string | null {
	if (!a.metar_station) return null;
	const age = a.obs_age_min == null ? '' : a.obs_age_min < 1 ? ', just now' : `, ${a.obs_age_min} min old`;
	return `Weather from ${a.metar_station}${age}`;
}
