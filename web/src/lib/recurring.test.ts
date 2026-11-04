import { describe, expect, it } from 'vitest';
import { formatDays, formatLocalTime } from './recurring';

describe('recurring formatting', () => {
	it('days', () => {
		expect(formatDays([1, 2, 3, 4, 5, 6, 7])).toBe('every day');
		expect(formatDays([1, 2, 3, 4, 5])).toBe('Mon–Fri');
		expect(formatDays([5, 1, 3])).toBe('Mon, Wed, Fri');
		expect(formatDays([6, 7])).toBe('weekends');
		expect(formatDays([1, 2, 3, 6])).toBe('Mon–Wed, Sat');
	});
	it('times', () => {
		expect(formatLocalTime('19:40:00')).toBe('7:40 pm');
		expect(formatLocalTime('00:05:00')).toBe('12:05 am');
		expect(formatLocalTime('12:00:00')).toBe('12:00 pm');
	});
});
