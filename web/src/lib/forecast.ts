import { clockTime, dayLabel } from './passes';
import type { ForecastPeriod } from './weather';
import { describeWeather } from './wx';

function when(iso: string, now: Date, timeZone?: string): string {
	const day = dayLabel(iso, now, timeZone);
	return `${day ? `${day} ` : ''}${clockTime(iso, timeZone)}`;
}

/** "Now–3:00 pm", "At times 6:00–8:00 pm", "30% chance, tomorrow 2:00–4:00 am". */
export function periodLabel(p: Pick<ForecastPeriod, 'change_type' | 'probability' | 'time_from' | 'time_to'>, now: Date, timeZone?: string): string {
	const started = new Date(p.time_from).getTime() <= now.getTime();
	const from = started ? 'Now' : when(p.time_from, now, timeZone);
	let to = when(p.time_to, now, timeZone);
	// "6:00 pm–8:00 pm" on the same day reads better as "6:00–8:00 pm"
	const f = from.match(/^(.*?)(\d{1,2}:\d{2}) (am|pm)$/);
	const t = to.match(/^(.*?)(\d{1,2}:\d{2}) (am|pm)$/);
	let range = `${from}–${to}`;
	if (f && t && f[1] === t[1] && f[3] === t[3] && !started) range = `${f[1]}${f[2]}–${t[2]} ${t[3]}`;
	switch (p.change_type) {
		case 'TEMPO':
			return `At times, ${lower(range)}`;
		case 'BECMG':
			return `Changing, ${lower(range)}`;
		case 'PROB':
			return `${p.probability ?? '?'}% chance, ${lower(range)}`;
		default:
			return range;
	}
}

const lower = (s: string) => (s.startsWith('Now') ? 'now' + s.slice(3) : s);

/** "Solid overcast at 3,000 ft above ground, light rain, visibility 3 miles" */
export function periodText(p: Pick<ForecastPeriod, 'change_type' | 'cloud_summary' | 'wx_string' | 'visibility_sm' | 'visibility_is_min'>): string {
	const parts: string[] = [];
	if (p.cloud_summary) parts.push(p.cloud_summary);
	else if (p.change_type === 'BECMG') parts.push('Cloud unchanged');
	const wx = describeWeather(p.wx_string);
	if (wx) parts.push(wx);
	if (p.visibility_sm != null && Number(p.visibility_sm) < 6) {
		const v = Number(p.visibility_sm);
		parts.push(`visibility ${v < 1 ? 'under 1 mile' : `${Number.isInteger(v) ? v : v.toFixed(1)} miles`}`);
	}
	if (!parts.length) return 'No change to the sky';
	const text = parts.join(', ');
	return text[0].toUpperCase() + text.slice(1);
}
