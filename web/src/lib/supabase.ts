import { createClient } from '@supabase/supabase-js';

const url = import.meta.env.VITE_SUPABASE_URL;
const key = import.meta.env.VITE_SUPABASE_ANON_KEY;

if (!url || !key) {
	throw new Error('Set VITE_SUPABASE_URL and VITE_SUPABASE_ANON_KEY (see web/.env.example)');
}

export const supabase = createClient(url, key, {
	auth: { persistSession: true, autoRefreshToken: true, detectSessionInUrl: true }
});
