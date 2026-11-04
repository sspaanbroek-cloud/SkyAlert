import { supabase } from './supabase';

/** Pending alerts for a spot, by prediction id. RLS: only your own. */
export async function pendingAlerts(spotId: string): Promise<Map<number, { manual: boolean; notify_at: string }>> {
	const { data, error } = await supabase
		.from('alert')
		.select('prediction_id, manual, notify_at')
		.eq('spot_id', spotId)
		.eq('status', 'pending');
	if (error) throw error;
	return new Map((data ?? []).map((a) => [a.prediction_id as number, { manual: a.manual as boolean, notify_at: a.notify_at as string }]));
}

/** "Remind me": notify `leadMin` minutes before the pass (or now if that's past). */
export async function remindMe(spotId: string, predictionId: number, passAtIso: string, leadMin: number) {
	const at = Math.max(Date.now(), new Date(passAtIso).getTime() - leadMin * 60_000);
	const { error } = await supabase.from('alert').insert({
		spot_id: spotId,
		prediction_id: predictionId,
		notify_at: new Date(at).toISOString(),
		manual: true
	});
	if (error && error.code !== '23505') throw error; // already set: fine
}

export async function cancelReminder(spotId: string, predictionId: number) {
	const { error } = await supabase
		.from('alert')
		.delete()
		.eq('spot_id', spotId)
		.eq('prediction_id', predictionId)
		.eq('status', 'pending');
	if (error) throw error;
}
