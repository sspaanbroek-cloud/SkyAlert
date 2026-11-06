/**
 * Turn what someone typed into an international (E.164) number:
 * "(415) 555-0101" -> "+14155550101" (10 digits = US/Canada),
 * "+44 7700 900123" -> "+447700900123". Returns null if it can't be a number.
 */
export function normalizePhone(input: string, defaultCountry = '1'): string | null {
	const trimmed = input.trim();
	const digits = trimmed.replace(/\D/g, '');
	let e164: string;
	if (trimmed.startsWith('+')) e164 = `+${digits}`;
	else if (trimmed.startsWith('00')) e164 = `+${digits.slice(2)}`;
	else if (defaultCountry === '1' && digits.length === 11 && digits.startsWith('1')) e164 = `+${digits}`;
	else if (digits.length === 10) e164 = `+${defaultCountry}${digits}`;
	else return null;
	return /^\+[1-9]\d{7,14}$/.test(e164) ? e164 : null;
}

/** "+14155550101" -> "+1 415 555 0101" for display (other countries: as given). */
export function formatPhone(e164: string): string {
	const p = e164.startsWith('+') ? e164 : `+${e164}`;
	const m = /^\+1(\d{3})(\d{3})(\d{4})$/.exec(p);
	return m ? `+1 ${m[1]} ${m[2]} ${m[3]}` : p;
}

export const SMS_CONSENT_TEXT =
	'Yes, send SkyAlert alert texts to this number. Up to 20 texts a day. Message and data rates may apply. Reply STOP to stop, HELP for help.';
