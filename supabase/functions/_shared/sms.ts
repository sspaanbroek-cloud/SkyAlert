// Text-message alerts via Twilio's Messaging API.
// Uses a Messaging Service (the registered sender carriers require in the US),
// which also handles STOP / HELP replies itself.

import type { ClaimedAlert } from './notify.ts';

export interface SmsResult {
	ok: boolean;
	/** Twilio error code, e.g. 21610 = this number replied STOP. */
	code?: number;
	status?: number;
	error?: string;
}

export const TWILIO_OPTED_OUT = 21610;

export interface TwilioConfig {
	accountSid: string;
	authToken: string;
	messagingServiceSid: string;
	fetch?: typeof fetch;
}

export function twilioSender(cfg: TwilioConfig) {
	const doFetch = cfg.fetch ?? fetch;
	const url = `https://api.twilio.com/2010-04-01/Accounts/${encodeURIComponent(cfg.accountSid)}/Messages.json`;
	const auth = 'Basic ' + btoa(`${cfg.accountSid}:${cfg.authToken}`);
	return async function sendSms(to: string, body: string): Promise<SmsResult> {
		try {
			const res = await doFetch(url, {
				method: 'POST',
				headers: { Authorization: auth, 'Content-Type': 'application/x-www-form-urlencoded' },
				body: new URLSearchParams({ To: to, MessagingServiceSid: cfg.messagingServiceSid, Body: body }),
				signal: AbortSignal.timeout(15000)
			});
			if (res.ok) {
				await res.body?.cancel();
				return { ok: true, status: res.status };
			}
			const err = (await res.json().catch(() => ({}))) as { code?: number; message?: string };
			return { ok: false, status: res.status, code: err.code, error: err.message ?? `Twilio ${res.status}` };
		} catch (e) {
			return { ok: false, error: (e as Error).message };
		}
	};
}

const RATING = { clear: 'Clear view', partial: 'Partly visible', hidden: 'Hidden by cloud', unknown: 'Visibility unknown' };
const POINTS = ['N', 'NE', 'E', 'SE', 'S', 'SW', 'W', 'NW'];
const SUFFIX = ' Reply STOP to opt out.';
const MAX = 160; // one standard text

/** Plain characters only, so the text stays one 160-character message. */
const ascii = (s: string) => s.normalize('NFKD').replace(/[^\x20-\x7e]/g, '').trim();

function clock(iso: string, timeZone: string): string {
	try {
		return new Date(iso).toLocaleTimeString('en-US', { hour: 'numeric', minute: '2-digit', timeZone }).replace(' AM', 'am').replace(' PM', 'pm');
	} catch {
		return new Date(iso).toISOString().slice(11, 16) + ' UTC';
	}
}

/** "SkyAlert: ASA123 overhead in 6 min. Clear view, 33,000 ft, look NE 62 deg up, 7:42pm. Kubota Garden. Reply STOP to opt out." */
export function buildSms(a: ClaimedAlert, now = new Date()): string {
	const who = ascii(a.callsign ?? a.icao24?.toUpperCase() ?? 'Aircraft') || 'Aircraft';
	const min = Math.round((new Date(a.closest_approach_at).getTime() - now.getTime()) / 60_000);
	const parts = [RATING[a.rating] ?? RATING.unknown];
	if (a.altitude_ft != null) parts.push(`${Math.round(a.altitude_ft).toLocaleString('en-US')} ft`);
	const el = a.elevation_deg == null ? null : Number(a.elevation_deg);
	const az = a.azimuth_deg == null ? null : Number(a.azimuth_deg);
	if (el != null && el >= 80) parts.push('straight up');
	else if (el != null && az != null) parts.push(`look ${POINTS[Math.round(az / 45) % 8]} ${Math.round(el)} deg up`);
	parts.push(clock(a.closest_approach_at, a.time_zone));
	const head = `SkyAlert: ${who} ${min <= 1 ? 'overhead now' : `overhead in ${min} min`}. ${parts.join(', ')}.`;
	const usual = a.basis === 'recurring' ? ' Usual flight, not yet tracked.' : '';
	let spot = ascii(a.spot_name);
	const room = MAX - head.length - usual.length - SUFFIX.length - 2; // " " + "."
	if (room < 4) spot = '';
	else if (spot.length > room) spot = spot.slice(0, room - 1).trimEnd() + '~';
	return `${head}${usual}${spot ? ` ${spot}.` : ''}${SUFFIX}`.slice(0, MAX);
}
