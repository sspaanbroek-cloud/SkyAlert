import { describe, expect, it } from 'vitest';
import { urlBase64ToUint8Array } from './push';

describe('urlBase64ToUint8Array', () => {
	it('decodes base64url without padding', () => {
		expect([...urlBase64ToUint8Array('AQID_-8')]).toEqual([1, 2, 3, 255, 239]);
	});
	it('decodes a 65-byte VAPID public key', () => {
		const key = 'BNcRdreALRFXTkOOUHK1EtK2wtaz5Ry4YfYCA_0QTpQtUbVlUls0VJXg7A8u-Ts1XbjhazAkj7I99e8QcYP7DkM';
		const bytes = urlBase64ToUint8Array(key);
		expect(bytes.length).toBe(65);
		expect(bytes[0]).toBe(4); // uncompressed P-256 point
	});
});
