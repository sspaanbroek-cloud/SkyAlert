import { createClient, type SupabaseClient } from '@supabase/supabase-js';

const url = import.meta.env.VITE_SUPABASE_URL;
const key = import.meta.env.VITE_SUPABASE_ANON_KEY;

/**
 * Set when the site was built without its Supabase settings. The layout shows
 * this instead of a blank page (it means: add the variables in Netlify and
 * redeploy).
 */
export const configError: string | null = !url || !key
	? `This copy of SkyAlert was built without ${[!url && 'VITE_SUPABASE_URL', !key && 'VITE_SUPABASE_ANON_KEY'].filter(Boolean).join(' and ')}. Add ${!url && !key ? 'them' : 'it'} in Netlify (Project configuration > Environment variables), then redeploy.`
	: !/^https:\/\/[a-z0-9-]+\.supabase\.co\/?$/.test(url) && !url.startsWith('http://')
		? `VITE_SUPABASE_URL should look like https://yourprojectid.supabase.co (it is "${url}"). Fix it in Netlify, then redeploy.`
		: null;

export const supabase: SupabaseClient = configError
	? (null as unknown as SupabaseClient)
	: createClient(url, key, {
			auth: { persistSession: true, autoRefreshToken: true, detectSessionInUrl: true }
		});
