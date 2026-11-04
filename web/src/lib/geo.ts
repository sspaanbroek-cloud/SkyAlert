// Small, dependency-free geo helpers shared by the UI.

export const M_PER_NM = 1852;
export const M_PER_FT = 0.3048;

export const ftToM = (ft: number) => ft * M_PER_FT;
export const mToFt = (m: number) => m / M_PER_FT;
export const nmToM = (nm: number) => nm * M_PER_NM;
export const mToNm = (m: number) => m / M_PER_NM;

export interface LatLon {
	lat: number;
	lon: number;
}

export function isValidLatLon({ lat, lon }: LatLon): boolean {
	return (
		Number.isFinite(lat) && Number.isFinite(lon) && lat >= -90 && lat <= 90 && lon >= -180 && lon <= 180
	);
}

/** EWKT for a PostGIS geography point. PostGIS order is longitude first. */
export function toEwktPoint(p: LatLon): string {
	if (!isValidLatLon(p)) throw new RangeError(`Invalid coordinates: ${p.lat}, ${p.lon}`);
	return `SRID=4326;POINT(${round(p.lon, 6)} ${round(p.lat, 6)})`;
}

/**
 * Horizontal distance at which an aircraft at `altitudeFt` sits exactly
 * `elevationDeg` above the horizon for an observer at `observerFt`.
 * Flat-earth approximation; fine at these ranges for a planning hint.
 */
export function horizontalDistanceNm(altitudeFt: number, elevationDeg: number, observerFt = 0): number {
	const heightM = ftToM(altitudeFt - observerFt);
	if (heightM <= 0 || elevationDeg <= 0) return Infinity;
	return mToNm(heightM / Math.tan((elevationDeg * Math.PI) / 180));
}

export function formatLatLon({ lat, lon }: LatLon): string {
	const ns = lat >= 0 ? 'N' : 'S';
	const ew = lon >= 0 ? 'E' : 'W';
	return `${Math.abs(lat).toFixed(4)}° ${ns}, ${Math.abs(lon).toFixed(4)}° ${ew}`;
}

export const formatFt = (ft: number) => `${Math.round(ft).toLocaleString('en-US')} ft`;

function round(n: number, dp: number) {
	const f = 10 ** dp;
	return Math.round(n * f) / f;
}
