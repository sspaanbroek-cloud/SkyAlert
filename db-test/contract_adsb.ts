// Prints the ingest_track_points() payload the ingest-adsb function would
// build from OpenSky state vectors, for run.sh to push through the real SQL.
import { parseStateVector } from '../supabase/functions/_shared/opensky.ts';

const now = Math.floor(Date.now() / 1000) - 5;
// Spot used by contract_adsb.sql: 47.5134 N, 122.2712 W.
// 1 deg latitude ~ 60 nm: 0.25 deg south ~ 15 nm out, flying north (true_track 0).
const states = [
	['c0ffee', 'SKA101  ', 'US', now, now, -122.2712, 47.2634, 10668, false, 231.5, 0, 0, null, 10820, '1200', false, 0, 4],
	['bad', 'X', 'US', now, now, 0, 0, 0, false, 0, 0, 0, null, 0, null, false, 0, 0]
];
console.log(JSON.stringify(states.map(parseStateVector).filter(Boolean)));
