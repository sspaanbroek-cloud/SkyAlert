import { supabase } from './supabase';

export interface RegularFlight {
	id: number;
	callsign: string;
	typical_local_time: string; // "19:40:00", in the spot's time zone
	days_of_week: number[]; // ISO: 1 = Monday
	observation_count: number;
	distinct_days: number;
	time_spread_min: number | null;
	typical_altitude_ft: number | null;
	typical_azimuth_deg: number | null;
	typical_elevation_deg: number | null;
	last_seen_at: string;
}

export async function listRegularFlights(spotId: string): Promise<RegularFlight[]> {
	const { data, error } = await supabase
		.from('recurring_flight')
		.select(
			'id, callsign, typical_local_time, days_of_week, observation_count, distinct_days, time_spread_min, typical_altitude_ft, typical_azimuth_deg, typical_elevation_deg, last_seen_at'
		)
		.eq('spot_id', spotId)
		.order('typical_local_time');
	if (error) throw error;
	return (data ?? []) as RegularFlight[];
}

const DAY = ['', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];

/** [1..7] -> "every day"; [1..5] -> "Mon–Fri"; [1,3,5] -> "Mon, Wed, Fri". */
export function formatDays(days: number[]): string {
	const d = [...new Set(days)].filter((x) => x >= 1 && x <= 7).sort((a, b) => a - b);
	if (d.length === 7) return 'every day';
	if (d.length === 0) return '';
	if (d.join() === '6,7') return 'weekends';
	const runs: number[][] = [];
	for (const x of d) {
		const last = runs.at(-1);
		if (last && x === last.at(-1)! + 1) last.push(x);
		else runs.push([x]);
	}
	return runs.map((r) => (r.length >= 3 ? `${DAY[r[0]]}–${DAY[r.at(-1)!]}` : r.map((x) => DAY[x]).join(', '))).join(', ');
}

/** "19:40:00" -> "7:40 pm" */
export function formatLocalTime(t: string): string {
	const [h, m] = t.split(':').map(Number);
	const ap = h >= 12 ? 'pm' : 'am';
	return `${h % 12 === 0 ? 12 : h % 12}:${String(m).padStart(2, '0')} ${ap}`;
}
