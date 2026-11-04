// Supabase Edge Function: fetch METARs around every spot from the Aviation
// Weather Center and store them. Called every 10 minutes by pg_cron
// (see migrations/*_schedules.sql). Auth: `x-ingest-secret` header.
import { createClient } from 'npm:@supabase/supabase-js@2';
import { createHandler } from './handler.ts';

const supabase = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!, {
	auth: { persistSession: false, autoRefreshToken: false }
});

Deno.serve(
	createHandler({
		rpc: async (fn, args) => {
			const { data, error } = await supabase.rpc(fn, args);
			return { data, error };
		},
		secret: Deno.env.get('INGEST_SECRET'),
		userAgent: 'SkyAlert/0.1 (+https://github.com/sspaanbroek-cloud/SkyAlert)'
	})
);
