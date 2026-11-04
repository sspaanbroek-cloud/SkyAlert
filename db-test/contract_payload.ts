// Prints the ingest_metars() payload the Edge Function would build from a few
// AWC-shaped records, so run.sh can push it through the real SQL function.
import { parseAwcMetar } from '../supabase/functions/_shared/metar.ts';

const t = Math.floor(Date.now() / 1000 / 60) * 60 - 600; // 10 minutes ago
const awc = [
	{ icaoId: 'KBFI', obsTime: t, rawOb: 'KBFI 041853Z 17006KT 10SM FEW025 BKN060 OVC090 12/08 A3001 RMK AO2',
	  lat: 47.5299, lon: -122.3019, elev: 6, name: 'Seattle/Boeing Fld, WA, US', visib: '10+', wdir: 170, wspd: 6,
	  temp: 12.2, dewp: 8.3, altim: 1016.3, fltCat: 'VFR', metarType: 'METAR' },
	{ icaoId: 'KRNT', obsTime: t, rawOb: 'KRNT 041853Z AUTO VRB03KT 10SM CLR 11/07 A3002 RMK AO2',
	  lat: 47.4931, lon: -122.2158, elev: 9, name: 'Renton Muni, WA, US', visib: '10+', wdir: 'VRB', wspd: 3 },
	{ icaoId: 'KSFO', obsTime: t, rawOb: 'SPECI KSFO 041856Z 28005KT 1/4SM FG VV002 11/11 A2995',
	  lat: 37.6196, lon: -122.3656, elev: 3, name: 'San Francisco Intl, CA, US', visib: 0.25, wdir: 280, wspd: 5 },
	{ icaoId: 'KMIA', obsTime: t, rawOb: 'KMIA 041853Z 09012G22KT 6SM TSRA SCT025CB BKN040TCU OVC100 27/24 A2990',
	  lat: 25.7881, lon: -80.3169, elev: 3, name: 'Miami Intl, FL, US', visib: 6, wdir: 90, wspd: 12, wgst: 22,
	  wxString: 'TSRA' }
];
const records = awc.map(parseAwcMetar).map((r) => {
	if (!r.ok) throw new Error(`${r.station}: ${r.reason}`);
	return r.record;
});
console.log(JSON.stringify(records));
