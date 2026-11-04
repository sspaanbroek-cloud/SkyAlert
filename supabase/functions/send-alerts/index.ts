// Supabase Edge Function: deliver due SkyAlert notifications by Web Push.
// Called every minute by pg_cron (migrations/*_alerts.sql).
// Secrets: INGEST_SECRET, VAPID_PUBLIC_KEY, VAPID_PRIVATE_KEY,
// VAPID_SUBJECT (a mailto: or https: contact, required by push services).
import { createClient } from 'npm:@supabase/supabase-js@2';
// @ts-types="npm:@types/web-push@3"
import webpush from 'npm:web-push@3';
import { createHandler } from './handler.ts';

const supabase = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!, {
	auth: { persistSession: false, autoRefreshToken: false }
});

webpush.setVapidDetails(
	Deno.env.get('VAPID_SUBJECT') ?? 'mailto:admin@example.com',
	Deno.env.get('VAPID_PUBLIC_KEY')!,
	Deno.env.get('VAPID_PRIVATE_KEY')!
);

Deno.serve(
	createHandler({
		rpc: async (fn, args) => {
			const { data, error } = await supabase.rpc(fn, args);
			return { data, error };
		},
		subscriptions: async (userIds) => {
			const { data, error } = await supabase
				.from('push_subscription')
				.select('user_id, endpoint, p256dh, auth')
				.in('user_id', userIds);
			if (error) throw error;
			return data ?? [];
		},
		send: async (sub, payload) => {
			try {
				await webpush.sendNotification(
					{ endpoint: sub.endpoint, keys: { p256dh: sub.p256dh, auth: sub.auth } },
					JSON.stringify(payload),
					{ TTL: 600, urgency: 'high', topic: payload.tag.slice(0, 32) }
				);
				return { ok: true };
			} catch (e) {
				const err = e as { statusCode?: number; message?: string };
				return { ok: false, status: err.statusCode, error: err.message };
			}
		},
		secret: Deno.env.get('INGEST_SECRET')
	})
);
