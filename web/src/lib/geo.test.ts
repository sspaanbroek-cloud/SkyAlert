import { describe, expect, it } from 'vitest';
import { formatLatLon, horizontalDistanceNm, isValidLatLon, mToFt, toEwktPoint } from './geo';

describe('toEwktPoint', () => {
	it('puts longitude first', () => {
		expect(toEwktPoint({ lat: 47.5134, lon: -122.2712 })).toBe('SRID=4326;POINT(-122.2712 47.5134)');
	});
	it('rounds to 6 dp', () => {
		expect(toEwktPoint({ lat: 1.23456789, lon: 2.3456789 })).toBe('SRID=4326;POINT(2.345679 1.234568)');
	});
	it('rejects out-of-range coordinates', () => {
		expect(() => toEwktPoint({ lat: 91, lon: 0 })).toThrow(RangeError);
		expect(() => toEwktPoint({ lat: 0, lon: NaN })).toThrow(RangeError);
	});
});

describe('horizontalDistanceNm', () => {
	it('airliner at FL350 is 20 deg up at about 15.8 nm', () => {
		expect(horizontalDistanceNm(35000, 20)).toBeCloseTo(15.8, 1);
	});
	it('accounts for observer elevation', () => {
		expect(horizontalDistanceNm(35000, 20, 5000)).toBeLessThan(horizontalDistanceNm(35000, 20));
	});
	it('is infinite at the horizon', () => {
		expect(horizontalDistanceNm(35000, 0)).toBe(Infinity);
	});
});

describe('misc', () => {
	it('validates lat/lon', () => {
		expect(isValidLatLon({ lat: -90, lon: 180 })).toBe(true);
		expect(isValidLatLon({ lat: 0, lon: 181 })).toBe(false);
	});
	it('formats coordinates', () => {
		expect(formatLatLon({ lat: 47.5134, lon: -122.2712 })).toBe('47.5134° N, 122.2712° W');
	});
	it('converts metres to feet', () => {
		expect(mToFt(100)).toBeCloseTo(328.08, 2);
	});
});
