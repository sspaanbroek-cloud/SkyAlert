import { describe, expect, it } from 'vitest';
import { formatPhone, normalizePhone } from './phone';

describe('normalizePhone', () => {
	it('US formats', () => {
		expect(normalizePhone('(415) 555-0101')).toBe('+14155550101');
		expect(normalizePhone('1 415 555 0101')).toBe('+14155550101');
		expect(normalizePhone('+1 415-555-0101')).toBe('+14155550101');
	});
	it('international', () => {
		expect(normalizePhone('+44 7700 900123')).toBe('+447700900123');
		expect(normalizePhone('0044 7700 900123')).toBe('+447700900123');
	});
	it('rejects junk', () => {
		expect(normalizePhone('555-0101')).toBeNull();
		expect(normalizePhone('call me')).toBeNull();
		expect(normalizePhone('+0123456789')).toBeNull();
	});
});

describe('formatPhone', () => {
	it('formats US and passes others through', () => {
		expect(formatPhone('14155550101')).toBe('+1 415 555 0101');
		expect(formatPhone('+447700900123')).toBe('+447700900123');
	});
});
