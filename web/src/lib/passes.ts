import { supabase } from './supabase';
import { compass } from './weather';

export interface Pass {
	id: number;
	basis: 'live_adsb' | 'filed_plan';
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
}

const COLUMNS =
	'id, basis, callsign, icao24, aircraft_type, closest_approach_at, closest_distance_nm, altitude_ft, azimuth_deg, elevation_deg, confidence, computed_at';

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
	return (data ?? []).map((p) => ({
		...p,
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
