// Supabase Edge Function: hourly model cloud cover (Open-Meteo) for every
// spot, then re-rate passes. Called by pg_cron (migrations/*_model_cloud.sql).
// Secrets: INGEST_SECRET (required); OPEN_METEO_API_KEY (optional, commercial).
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
		apiKey: Deno.env.get('OPEN_METEO_API_KEY') || undefined,
		secret: Deno.env.get('INGEST_SECRET'),
		userAgent: 'SkyAlert/0.1 (+https://github.com/sspaanbroek-cloud/SkyAlert)'
	})
);
