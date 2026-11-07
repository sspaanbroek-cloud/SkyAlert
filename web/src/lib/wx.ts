// Plain-language versions of METAR/TAF weather codes and lightning remarks.

const DESCRIPTOR: Record<string, string> = {
	MI: 'shallow', PR: 'partial', BC: 'patches of', DR: 'low drifting', BL: 'blowing', FZ: 'freezing'
};
const PHENOMENON: Record<string, string> = {
	DZ: 'drizzle', RA: 'rain', SN: 'snow', SG: 'snow grains', IC: 'ice crystals', PL: 'ice pellets',
	GR: 'hail', GS: 'small hail', UP: 'unknown precipitation', BR: 'mist', FG: 'fog', FU: 'smoke',
	VA: 'volcanic ash', DU: 'dust', SA: 'sand', HZ: 'haze', PY: 'spray', PO: 'dust whirls',
	SQ: 'squalls', FC: 'funnel cloud', SS: 'sandstorm', DS: 'duststorm'
};
const TOKEN = /^(\+|-|VC)?(MI|PR|BC|DR|BL|SH|TS|FZ)?((?:DZ|RA|SN|SG|IC|PL|GR|GS|UP|BR|FG|FU|VA|DU|SA|HZ|PY|PO|SQ|FC|SS|DS)*)$/;

function describeToken(token: string): string {
	const m = TOKEN.exec(token);
	if (!m || (!m[2] && !m[3])) return token; // unknown: leave as reported
	const [, intensity, descriptor, rest] = m;
	const things = (rest.match(/../g) ?? []).map((c) => PHENOMENON[c]);
	if (intensity === '+' && rest === 'FC') return 'tornado or waterspout';
	let text: string;
	if (descriptor === 'TS') text = things.length ? `thunderstorm with ${things.join(' and ')}` : 'thunderstorm';
	else if (descriptor === 'SH') text = things.length ? `${things.join(' and ')} showers` : 'showers';
	else text = [descriptor ? DESCRIPTOR[descriptor] : '', things.join(' and ')].filter(Boolean).join(' ');
	if (intensity === '-') text = `light ${text}`;
	if (intensity === '+') text = `heavy ${text}`;
	if (intensity === 'VC') text = `${text} nearby`;
	return text;
}

/** "-SHRA BR" -> "light rain showers, mist"; "VCTS" -> "thunderstorm nearby". */
export function describeWeather(wx: string | null | undefined): string | null {
	if (!wx?.trim()) return null;
	return wx.trim().split(/\s+/).map(describeToken).join(', ');
}

/** True when a weather string reports or forecasts a thunderstorm. */
export const hasThunder = (wx: string | null | undefined) => /TS/.test(wx ?? '');

const FREQUENCY: Record<string, string> = { OCNL: 'occasional', FRQ: 'frequent', CONS: 'continuous' };
const LTG_TYPE: Record<string, string> = { IC: 'in-cloud', CC: 'cloud-to-cloud', CG: 'cloud-to-ground', CA: 'cloud-to-air' };
const DISTANCE: Record<string, string> = {
	DSNT: 'distant (10 to 30 miles)', VC: 'nearby (5 to 10 miles)', OHD: 'overhead', ALQDS: 'all around'
};

/** "OCNL LTGICCG DSNT NE" -> "Lightning reported: occasional, in-cloud and cloud-to-ground, distant (10 to 30 miles), to the NE" */
export function describeLightning(remark: string | null | undefined): string | null {
	if (!remark?.trim()) return null;
	const parts: string[] = [];
	const where: string[] = [];
	const dirs: string[] = [];
	for (const w of remark.trim().split(/\s+/)) {
		if (FREQUENCY[w]) parts.push(FREQUENCY[w]);
		else if (w.startsWith('LTG')) {
			const types = (w.slice(3).match(/IC|CC|CG|CA/g) ?? []).map((t) => LTG_TYPE[t]);
			if (types.length) parts.push(types.join(' and '));
		} else if (DISTANCE[w]) where.push(DISTANCE[w]);
		else if (/^[NSEW]{1,2}(-[NSEW]{1,2})*$/.test(w)) dirs.push(w.replace(/-/g, '–'));
	}
	if (dirs.length) where.push(`to the ${dirs.join(' and ')}`);
	const detail = [...parts, ...where].join(', ');
	return `Lightning reported${detail ? `: ${detail}` : ''}`;
}
