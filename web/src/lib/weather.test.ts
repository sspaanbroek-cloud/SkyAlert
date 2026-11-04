import { describe, expect, it } from 'vitest';
import { compass, formatAge, formatVisibility } from './weather';

describe('weather formatting', () => {
	it('compass points', () => {
		expect([0, 44, 46, 180, 315, 359, 360].map(compass)).toEqual(['N', 'NE', 'NE', 'S', 'NW', 'N', 'N']);
	});
	it('ages', () => {
		expect(formatAge(0)).toBe('just now');
		expect(formatAge(12)).toBe('12 min ago');
		expect(formatAge(60)).toBe('1 h ago');
		expect(formatAge(95)).toBe('1 h 35 min ago');
	});
	it('visibility', () => {
		expect(formatVisibility({ visibility_sm: 10, visibility_is_min: true })).toBe('over 10 mi visibility');
		expect(formatVisibility({ visibility_sm: 0.25, visibility_is_min: false })).toBe('0.25 mi visibility');
		expect(formatVisibility({ visibility_sm: 1.5, visibility_is_min: false })).toBe('1.5 mi visibility');
		expect(formatVisibility({ visibility_sm: null, visibility_is_min: false })).toBeNull();
	});
});
