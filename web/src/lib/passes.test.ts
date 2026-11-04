import { describe, expect, it } from 'vitest';
import { clockTime, confidenceLabel, dayLabel, flightLabel, headline, lookLabel, weatherSource, whenLabel } from './passes';

const now = new Date('2026-11-04T19:36:00Z');
const at = (s: number) => new Date(now.getTime() + s * 1000).toISOString();

describe('pass labels', () => {
	it('when', () => {
		expect(whenLabel(at(-120), now)).toBe('Just passed');
		expect(whenLabel(at(30), now)).toBe('Passing now');
		expect(whenLabel(at(360), now)).toBe('in 6 min');
		expect(whenLabel(at(3900), now)).toBe('in 1 h 5 min');
	});
	it('clock time in a given zone', () => {
		expect(clockTime('2026-11-05T03:42:00Z', 'America/Los_Angeles')).toBe('7:42 pm');
	});
	it('where to look', () => {
		expect(lookLabel({ azimuth_deg: 45, elevation_deg: 62.4 })).toBe('Look NE (45°), 62° above the horizon');
		expect(lookLabel({ azimuth_deg: 10, elevation_deg: 85 })).toBe('Straight overhead');
		expect(lookLabel({ azimuth_deg: null, elevation_deg: null })).toBeNull();
	});
	it('confidence', () => {
		expect([0.9, 0.75, 0.6, 0.3, null].map(confidenceLabel)).toEqual(['High', 'High', 'Medium', 'Low', null]);
	});
	it('flight label falls back to hex id', () => {
		expect(flightLabel({ callsign: null, icao24: 'a1b2c3' })).toBe('A1B2C3');
		expect(flightLabel({ callsign: 'ASA123', icao24: 'a1b2c3' })).toBe('ASA123');
	});
});

describe('assessment text', () => {
	it('headline matches the brief', () => {
		expect(
			headline(
				{ callsign: 'ASA123', icao24: 'a1b2c3', altitude_ft: 33000, closest_approach_at: '2026-11-05T03:42:00Z' },
				'America/Los_Angeles',
				new Date('2026-11-05T01:00:00Z') // 5 pm the same local day
			)
		).toBe('ASA123, 33,000 ft, passes at 7:42 pm.');
	});
	it('weather source', () => {
		expect(weatherSource({ metar_station: 'KBFI', obs_age_min: 12, weather_basis: 'metar' })).toBe('Weather from KBFI, 12 min old');
		expect(weatherSource({ metar_station: 'KSEA', obs_age_min: 200, weather_basis: 'taf' })).toBe('Forecast from KSEA, issued 3 h ago');
		expect(weatherSource({ metar_station: 'KBFI', obs_age_min: 5, weather_basis: 'metar_persistence' })).toBe(
			'Current weather from KBFI, 5 min old'
		);
		expect(weatherSource({ metar_station: null, obs_age_min: null, weather_basis: 'none' })).toBeNull();
	});
});

describe('day labels in the spot time zone', () => {
	const tz = 'America/Los_Angeles';
	const now = new Date('2026-11-05T01:00:00Z'); // Wed 4 Nov, 5 pm local
	it('today is blank', () => expect(dayLabel('2026-11-05T03:42:00Z', now, tz)).toBe(''));
	it('tomorrow', () => expect(dayLabel('2026-11-05T15:10:00Z', now, tz)).toBe('tomorrow'));
	it('weekday further out', () => expect(dayLabel('2026-11-07T03:40:00Z', now, tz)).toBe('Fri'));
	it('headline with day', () =>
		expect(
			headline({ callsign: 'WKDY2', icao24: null, altitude_ft: null, closest_approach_at: '2026-11-05T15:10:00Z' }, tz, now)
		).toBe('WKDY2, passes tomorrow at 7:10 am.'));
});
