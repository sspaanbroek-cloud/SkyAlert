// The source-neutral flight-plan record that public.ingest_flight_plans()
// accepts. A FlightAware AeroAPI or FAA SWIM adapter only needs to produce
// these; route resolution, ETAs, altitudes and predictions happen in SQL.

export interface FlightPlanInput {
	/** e.g. 'aeroapi' or 'faa_swim'. Unique together with source_ref. */
	source: string;
	/** The flight's id in that source (AeroAPI fa_flight_id, SWIM gufi). */
	source_ref: string;
	callsign: string;
	/** ICAO airport ids, e.g. 'KSEA'. */
	origin: string;
	destination: string;
	/** ICAO type designator, e.g. 'B738'. */
	aircraft_type?: string | null;
	rules?: 'IFR' | 'VFR' | 'Y' | 'Z' | null;
	filed_cruise_ft?: number | null;
	/** Filed true airspeed, used as ground speed for ETAs (420 kt if missing). */
	filed_speed_kt?: number | null;
	/** Filed (or estimated) departure time, ISO 8601. */
	filed_etd: string;
	/** As filed, e.g. 'KSEA SUMMA1 SUMMA J70 LKV DCT 4130N12030W KSFO'. */
	route_string: string;
	status?: 'filed' | 'active' | 'completed' | 'cancelled' | 'unknown';
}

/** Basic checks before sending a batch; returns a reason or null. */
export function validatePlan(p: FlightPlanInput): string | null {
	if (!p.source || !p.source_ref) return 'missing source or source_ref';
	if (!/^[A-Z0-9]{2,8}$/i.test(p.callsign ?? '')) return 'missing or invalid callsign';
	if (!/^[A-Z0-9]{3,4}$/i.test(p.origin ?? '') || !/^[A-Z0-9]{3,4}$/i.test(p.destination ?? '')) return 'invalid origin or destination';
	if (Number.isNaN(Date.parse(p.filed_etd))) return 'invalid filed_etd';
	if (p.filed_cruise_ft != null && (p.filed_cruise_ft < 0 || p.filed_cruise_ft > 60000)) return 'filed_cruise_ft out of range';
	if (p.filed_speed_kt != null && (p.filed_speed_kt < 50 || p.filed_speed_kt > 700)) return 'filed_speed_kt out of range';
	return null;
}
