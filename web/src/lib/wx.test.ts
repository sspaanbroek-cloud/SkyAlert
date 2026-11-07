import { describe, expect, it } from 'vitest';
import { describeLightning, describeWeather, hasThunder } from './wx';

describe('describeWeather', () => {
	it.each([
		['-RA', 'light rain'],
		['-SHRA BR', 'light rain showers, mist'],
		['+TSRA', 'heavy thunderstorm with rain'],
		['VCTS', 'thunderstorm nearby'],
		['VCSH', 'showers nearby'],
		['FZFG', 'freezing fog'],
		['BCFG', 'patches of fog'],
		['-RASN', 'light rain and snow'],
		['BLSN', 'blowing snow'],
		['+FC', 'tornado or waterspout'],
		['HZ', 'haze'],
		['XYZ', 'XYZ']
	])('%s -> %s', (code, text) => expect(describeWeather(code)).toBe(text));
	it('empty', () => {
		expect(describeWeather(null)).toBeNull();
		expect(describeWeather('  ')).toBeNull();
	});
	it('thunder', () => {
		expect(hasThunder('VCTS')).toBe(true);
		expect(hasThunder('-RA')).toBe(false);
	});
});

describe('describeLightning', () => {
	it('full remark', () =>
		expect(describeLightning('OCNL LTGICCG DSNT NE')).toBe(
			'Lightning reported: occasional, in-cloud and cloud-to-ground, distant (10 to 30 miles), to the NE'
		));
	it('direction range', () => expect(describeLightning('LTG DSNT W-NW')).toBe('Lightning reported: distant (10 to 30 miles), to the W–NW'));
	it('overhead and nearby', () =>
		expect(describeLightning('FRQ LTGCG OHD AND VC')).toBe('Lightning reported: frequent, cloud-to-ground, overhead, nearby (5 to 10 miles)'));
	it('bare', () => expect(describeLightning('LTG')).toBe('Lightning reported'));
	it('none', () => expect(describeLightning(null)).toBeNull());
});
