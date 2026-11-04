// Supabase Edge Function: poll OpenSky for aircraft around every spot, store
// positions and recompute live overflight predictions. Called every minute by
// pg_cron (migrations/*_adsb.sql). Auth: `x-ingest-secret` header.
//
// Secrets: INGEST_SECRET (required), OPENSKY_CLIENT_ID + OPENSKY_CLIENT_SECRET
// (recommended; without them OpenSky's small anonymous allowance applies).
import { createClient } from 'npm:@supabase/supabase-js@2';
import { OpenSkyClient } from '../_shared/opensky.ts';
import { createHandler } from './handler.ts';

const supabase = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!, {
	auth: { persistSession: false, autoRefreshToken: false }
});

// Module scope: the OAuth token is reused across invocations while the worker is warm.
const opensky = new OpenSkyClient({
	clientId: Deno.env.get('OPENSKY_CLIENT_ID'),
	clientSecret: Deno.env.get('OPENSKY_CLIENT_SECRET'),
	userAgent: 'SkyAlert/0.1 (+https://github.com/sspaanbroek-cloud/SkyAlert)'
});

Deno.serve(
	createHandler({
		rpc: async (fn, args) => {
			const { data, error } = await supabase.rpc(fn, args);
			return { data, error };
		},
		opensky,
		secret: Deno.env.get('INGEST_SECRET')
	})
);
