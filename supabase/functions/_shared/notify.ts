// Notification wording for a claimed alert (see claim_due_alerts()).

export interface ClaimedAlert {
	alert_id: number;
	user_id: string;
	spot_id: string;
	spot_name: string;
	time_zone: string;
	prediction_id: number;
	basis: 'live_adsb' | 'recurring' | 'filed_plan';
	callsign: string | null;
	icao24: string | null;
	closest_approach_at: string;
	closest_distance_nm: number | string | null;
	altitude_ft: number | null;
	azimuth_deg: number | string | null;
	elevation_deg: number | string | null;
	rating: 'clear' | 'partial' | 'hidden' | 'unknown';
	manual: boolean;
}

export interface PushPayload {
	title: string;
	body: string;
	tag: string;
	url: string;
}

const RATING = { clear: 'Clear view', partial: 'Partly visible', hidden: 'Hidden by cloud', unknown: 'Visibility unknown' };
const POINTS = ['N', 'NE', 'E', 'SE', 'S', 'SW', 'W', 'NW'];

function clock(iso: string, timeZone: string): string {
	try {
		return new Date(iso).toLocaleTimeString('en-US', { hour: 'numeric', minute: '2-digit', timeZone }).replace(' AM', ' am').replace(' PM', ' pm');
	} catch {
		return new Date(iso).toISOString().slice(11, 16) + ' UTC';
	}
}

export function buildPayload(a: ClaimedAlert, now = new Date()): PushPayload {
	const who = a.callsign ?? a.icao24?.toUpperCase() ?? 'An aircraft';
	const min = Math.round((new Date(a.closest_approach_at).getTime() - now.getTime()) / 60_000);
	const when = min <= 1 ? 'overhead now' : `overhead in ${min} min`;

	const parts: string[] = [RATING[a.rating] ?? RATING.unknown];
	if (a.altitude_ft != null) parts.push(`${Math.round(a.altitude_ft).toLocaleString('en-US')} ft`);
	const el = a.elevation_deg == null ? null : Number(a.elevation_deg);
	const az = a.azimuth_deg == null ? null : Number(a.azimuth_deg);
	if (el != null && el >= 80) parts.push('straight overhead');
	else if (el != null && az != null) parts.push(`look ${POINTS[Math.round(az / 45) % 8]}, ${Math.round(el)}° up`);
	parts.push(`at ${clock(a.closest_approach_at, a.time_zone)}`);

	const where = a.basis === 'recurring' ? `${a.spot_name} (usual flight, not yet tracked)` : a.spot_name;
	return {
		title: `${who} ${when}`,
		body: `${parts.join(' · ')}\n${where}`,
		tag: `pass-${a.prediction_id}`,
		url: `/spots/${a.spot_id}`
	};
}
