import { describe, expect, it } from 'vitest';
import { periodLabel, periodText } from './forecast';

const tz = 'America/Los_Angeles';
const now = new Date('2026-11-07T20:00:00Z'); // 12:00 pm local, Sat
const at = (h: number) => new Date(now.getTime() + h * 3600_000).toISOString();

describe('periodLabel', () => {
	it('current base period', () =>
		expect(periodLabel({ change_type: 'BASE', probability: null, time_from: at(-1), time_to: at(3) }, now, tz)).toBe('Now–3:00 pm'));
	it('tempo later today', () =>
		expect(periodLabel({ change_type: 'TEMPO', probability: null, time_from: at(6), time_to: at(8) }, now, tz)).toBe('At times, 6:00–8:00 pm'));
	it('prob tomorrow', () =>
		expect(periodLabel({ change_type: 'PROB', probability: 30, time_from: at(14), time_to: at(16) }, now, tz)).toBe(
			'30% chance, tomorrow 2:00–4:00 am'
		));
	it('FM running past midnight', () =>
		expect(periodLabel({ change_type: 'FM', probability: null, time_from: at(3), time_to: at(23) }, now, tz)).toBe(
			'3:00 pm–tomorrow 11:00 am'
		));
	it('becoming', () =>
		expect(periodLabel({ change_type: 'BECMG', probability: null, time_from: at(-0.5), time_to: at(1) }, now, tz)).toBe(
			'Changing, now–1:00 pm'
		));
});

describe('periodText', () => {
	it('cloud, weather, visibility', () =>
		expect(
			periodText({ change_type: 'FM', cloud_summary: 'Solid overcast at 3,000 ft above ground', wx_string: '-RA', visibility_sm: 3, visibility_is_min: false })
		).toBe('Solid overcast at 3,000 ft above ground, light rain, visibility 3 miles'));
	it('good visibility not mentioned', () =>
		expect(periodText({ change_type: 'BASE', cloud_summary: 'Clear sky', wx_string: null, visibility_sm: 6, visibility_is_min: true })).toBe(
			'Clear sky'
		));
	it('wind-only change', () =>
		expect(periodText({ change_type: 'BECMG', cloud_summary: null, wx_string: null, visibility_sm: null, visibility_is_min: false })).toBe(
			'Cloud unchanged'
		));
	it('fog', () =>
		expect(periodText({ change_type: 'PROB', cloud_summary: 'Sky obscured (fog, haze or precipitation) at 200 ft above ground', wx_string: 'FG', visibility_sm: 0.5, visibility_is_min: false })).toBe(
			'Sky obscured (fog, haze or precipitation) at 200 ft above ground, fog, visibility under 1 mile'
		));
});
