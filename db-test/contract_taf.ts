// Prints the ingest_tafs() payload built by the TS parser from an AWC-shaped
// TAF valid from an hour ago, for run.sh to push through the real SQL.
import { parseAwcTaf } from '../supabase/functions/_shared/taf.ts';

const t0 = Math.floor(Date.now() / 1000 / 3600) * 3600 - 3600;
const r = parseAwcTaf({
	icaoId: 'KSEA', issueTime: new Date((t0 - 1200) * 1000).toISOString(), validTimeFrom: t0, validTimeTo: t0 + 30 * 3600,
	rawTAF: 'TAF KSEA contract', lat: 47.4447, lon: -122.3144, elev: 132, name: 'Seattle-Tacoma Intl, WA, US',
	fcsts: [
		{ timeFrom: t0, timeTo: t0 + 4 * 3600, fcstChange: null, visib: '6+', clouds: [{ cover: 'BKN', base: 6000 }] },
		{ timeFrom: t0 + 4 * 3600, timeTo: t0 + 30 * 3600, fcstChange: 'FM', visib: '6+', clouds: [{ cover: 'OVC', base: 3000 }] }
	]
});
if (!r.ok) throw new Error(r.reason);
console.log(JSON.stringify([r.record]));
