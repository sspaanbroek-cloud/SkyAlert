import type { Session } from '@supabase/supabase-js';
import { supabase } from './supabase';

/** Reactive auth state. `ready` flips once the stored session has been read. */
export const auth = $state<{ session: Session | null; ready: boolean }>({
	session: null,
	ready: false
});

supabase.auth.getSession().then(({ data }) => {
	auth.session = data.session;
	auth.ready = true;
});

supabase.auth.onAuthStateChange((_event, session) => {
	auth.session = session;
	auth.ready = true;
});
