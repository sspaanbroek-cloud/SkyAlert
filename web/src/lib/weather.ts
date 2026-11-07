import { supabase } from './supabase';

export interface StationWeather {
	station: string;
	station_name: string | null;
	distance_nm: number;
	bearing_deg: number;
	station_elevation_ft: number;
	observed_at: string;
	age_min: number;
	flight_category: 'VFR' | 'MVFR' | 'IFR' | 'LIFR' | null;
	is_auto: boolean;
	visibility_sm: number | null;
	visibility_is_min: boolean;
	wx_string: string | null;
	raw_text: string;
	sky_summary: string;
	layers: { cover: string; cloud_type: string | null; base_agl_ft: number; base_msl_ft: number; plain_label: string }[];
	/** Lightning phrase from the METAR remarks, e.g. "OCNL LTGICCG DSNT NE". */
	lightning_remark: string | null;
}

export interface ForecastPeriod {
	station: string;
	station_name: string | null;
	distance_nm: number;
	bearing_deg: number;
	issued_at: string;
	issued_age_min: number;
	valid_to: string;
	raw_text: string;
	seq: number;
	change_type: 'BASE' | 'FM' | 'BECMG' | 'TEMPO' | 'PROB';
	probability: number | null;
	time_from: string;
	time_to: string;
	cloud_summary: string | null;
	visibility_sm: number | null;
	visibility_is_min: boolean;
	wx_string: string | null;
	thunder: boolean;
}

/** The nearest airport forecast (TAF), as its change groups over the next `hours`. */
export async function getNearbyForecast(spotId: string, hours = 12): Promise<ForecastPeriod[]> {
	const { data, error } = await supabase.rpc('nearby_forecast', { p_spot_id: spotId, p_hours: hours });
	if (error) throw error;
	return (data ?? []) as ForecastPeriod[];
}

/** Reports older than this are flagged: METARs are normally hourly. */
export const STALE_AFTER_MIN = 90;

export async function getNearbyWeather(spotId: string, limit = 3): Promise<StationWeather[]> {
	const { data, error } = await supabase.rpc('nearby_weather', { p_spot_id: spotId, p_limit: limit });
	if (error) throw error;
	return (data ?? []) as StationWeather[];
}

const POINTS = ['N', 'NE', 'E', 'SE', 'S', 'SW', 'W', 'NW'];
export const compass = (deg: number) => POINTS[Math.round((((deg % 360) + 360) % 360) / 45) % 8];

export function formatAge(min: number): string {
	if (min < 1) return 'just now';
	if (min < 60) return `${min} min ago`;
	const h = Math.floor(min / 60);
	const m = min % 60;
	return m ? `${h} h ${m} min ago` : `${h} h ago`;
}

export function formatVisibility(w: Pick<StationWeather, 'visibility_sm' | 'visibility_is_min'>): string | null {
	if (w.visibility_sm == null) return null;
	const v = Number(w.visibility_sm);
	return `${w.visibility_is_min ? 'over ' : ''}${Number.isInteger(v) ? v : v.toFixed(2).replace(/0$/, '')} mi visibility`;
}
