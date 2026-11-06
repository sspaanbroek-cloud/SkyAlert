import { supabase } from './supabase';
import { SMS_CONSENT_TEXT } from './phone';

export interface NotificationPref {
	push_enabled: boolean;
	sms_enabled: boolean;
	sms_opted_out_at: string | null;
}

export async function getPrefs(): Promise<NotificationPref> {
	const { data, error } = await supabase
		.from('notification_pref')
		.select('push_enabled, sms_enabled, sms_opted_out_at')
		.maybeSingle();
	if (error) throw error;
	return (data as NotificationPref | null) ?? { push_enabled: true, sms_enabled: false, sms_opted_out_at: null };
}

/** Switch text alerts on (recording consent) or off. */
export async function setSmsEnabled(on: boolean): Promise<void> {
	const row: Record<string, string | boolean> = on
		? { sms_enabled: true, sms_consent_at: new Date().toISOString(), sms_consent_text: SMS_CONSENT_TEXT }
		: { sms_enabled: false };
	const { error } = await supabase.from('notification_pref').upsert(row, { onConflict: 'user_id' });
	if (error) throw error;
}
