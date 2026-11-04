import { supabase } from './supabase';
import { toEwktPoint, type LatLon } from './geo';

export interface Spot {
	id: string;
	name: string;
	lat: number;
	lon: number;
	elevation_ft: number;
	search_radius_nm: number;
	min_elevation_deg: number;
	time_zone: string;
	updated_at: string;
}

export interface SpotInput extends LatLon {
	name: string;
	elevation_ft: number;
	search_radius_nm: number;
	min_elevation_deg: number;
	time_zone: string;
}

export const SPOT_DEFAULTS = { search_radius_nm: 10, min_elevation_deg: 20 } as const;

const COLUMNS = 'id, name, lat, lon, elevation_ft, search_radius_nm, min_elevation_deg, time_zone, updated_at';

// numeric columns come back as numbers from PostgREST, but be defensive.
function normalize(row: Record<string, unknown>): Spot {
	return {
		...(row as unknown as Spot),
		lat: Number(row.lat),
		lon: Number(row.lon),
		elevation_ft: Number(row.elevation_ft),
		search_radius_nm: Number(row.search_radius_nm),
		min_elevation_deg: Number(row.min_elevation_deg)
	};
}

function toRow(input: SpotInput) {
	return {
		name: input.name.trim(),
		geog: toEwktPoint(input),
		elevation_ft: Math.round(input.elevation_ft),
		search_radius_nm: input.search_radius_nm,
		min_elevation_deg: input.min_elevation_deg,
		time_zone: input.time_zone
	};
}

export async function listSpots(): Promise<Spot[]> {
	const { data, error } = await supabase.from('spot').select(COLUMNS).order('name');
	if (error) throw error;
	return data.map(normalize);
}

export async function getSpot(id: string): Promise<Spot | null> {
	const { data, error } = await supabase.from('spot').select(COLUMNS).eq('id', id).maybeSingle();
	if (error) throw error;
	return data ? normalize(data) : null;
}

export async function createSpot(input: SpotInput): Promise<Spot> {
	const { data, error } = await supabase.from('spot').insert(toRow(input)).select(COLUMNS).single();
	if (error) throw error;
	return normalize(data);
}

export async function updateSpot(id: string, input: SpotInput): Promise<Spot> {
	const { data, error } = await supabase
		.from('spot')
		.update(toRow(input))
		.eq('id', id)
		.select(COLUMNS)
		.single();
	if (error) throw error;
	return normalize(data);
}

export async function deleteSpot(id: string): Promise<void> {
	const { error } = await supabase.from('spot').delete().eq('id', id);
	if (error) throw error;
}

/** Turn a Supabase/PostgREST error into something a person can act on. */
export function describeError(e: unknown): string {
	const err = e as { code?: string; message?: string };
	switch (err?.code) {
		case '23514':
			return 'One of the values is out of range. Check the radius (up to 100 nm) and elevation angle (0 to 90°).';
		case '22023':
			return 'That time zone is not recognised.';
		case '42501':
			return 'You do not have permission to change this spot. Try signing in again.';
		case 'PGRST116':
			return 'That spot was not found.';
	}
	return err?.message ?? 'Something went wrong.';
}

/** The browser's own time zone, the default for a new spot. */
export function browserTimeZone(): string {
	try {
		return Intl.DateTimeFormat().resolvedOptions().timeZone || 'UTC';
	} catch {
		return 'UTC';
	}
}

export function timeZoneOptions(current: string): string[] {
	let zones: string[] = [];
	try {
		zones = (Intl as unknown as { supportedValuesOf(k: string): string[] }).supportedValuesOf('timeZone');
	} catch {
		zones = [];
	}
	return [...new Set(['UTC', current, ...zones])].sort();
}
