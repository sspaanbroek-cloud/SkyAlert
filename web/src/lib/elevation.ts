import { mToFt, type LatLon } from './geo';

/**
 * Ground elevation (ft MSL) from the Open-Meteo elevation API (free, no key,
 * ~90 m Copernicus DEM). Returns null on any failure; the user can type it in.
 */
export async function lookupElevationFt({ lat, lon }: LatLon, signal?: AbortSignal): Promise<number | null> {
	try {
		const url = `https://api.open-meteo.com/v1/elevation?latitude=${lat}&longitude=${lon}`;
		const res = await fetch(url, { signal });
		if (!res.ok) return null;
		const body = (await res.json()) as { elevation?: number[] };
		const m = body.elevation?.[0];
		return typeof m === 'number' && Number.isFinite(m) ? Math.round(mToFt(m)) : null;
	} catch {
		return null;
	}
}
