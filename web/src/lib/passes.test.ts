import { describe, expect, it } from 'vitest';
import { clockTime, confidenceLabel, flightLabel, lookLabel, whenLabel } from './passes';

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
