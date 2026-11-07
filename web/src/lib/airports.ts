import { supabase } from './supabase';

export interface AirportMatch {
	ident: string;
	/** Code to show: ICAO (KSEA), else GPS/FAA code (0S9). */
	code: string;
	name: string;
	municipality: string | null;
	iso_country: string | null;
	type: 'small_airport' | 'medium_airport' | 'large_airport';
	lat: number;
	lon: number;
	elevation_ft: number | null;
	matched: 'icao' | 'iata' | 'local';
}

/** Airports for an ICAO, IATA or FAA code, best match first (up to 5). */
export async function findAirport(code: string): Promise<AirportMatch[]> {
	const c = code.trim();
	if (c.length < 2) return [];
	const { data, error } = await supabase.rpc('find_airport', { p_code: c });
	if (error) throw error;
	return (data ?? []) as AirportMatch[];
}

export const airportPlace = (a: Pick<AirportMatch, 'municipality' | 'iso_country'>) =>
	[a.municipality, a.iso_country].filter(Boolean).join(', ');
