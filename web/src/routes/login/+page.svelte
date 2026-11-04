<script lang="ts">
	import { supabase } from '#lib/supabase.ts';

	let mode: 'signin' | 'signup' = $state('signin');
	let email = $state('');
	let password = $state('');
	let busy = $state(false);
	let error = $state('');
	let notice = $state('');

	async function submit(e: SubmitEvent) {
		e.preventDefault();
		busy = true;
		error = notice = '';
		try {
			if (mode === 'signin') {
				const { error: err } = await supabase.auth.signInWithPassword({ email, password });
				if (err) throw err;
				// layout redirects once the session arrives
			} else {
				const { data, error: err } = await supabase.auth.signUp({
					email,
					password,
					options: { emailRedirectTo: location.origin }
				});
				if (err) throw err;
				if (!data.session) notice = 'Check your email for a confirmation link, then sign in.';
			}
		} catch (err) {
			error = (err as Error).message;
		} finally {
			busy = false;
		}
	}
</script>

<h1>{mode === 'signin' ? 'Sign in' : 'Create an account'}</h1>
<p class="hint">Save your shooting spots and see which aircraft will pass overhead, and whether cloud will hide them.</p>

<form class="card" onsubmit={submit}>
	<label for="email">Email</label>
	<input id="email" type="email" autocomplete="email" required bind:value={email} />

	<label for="password">Password</label>
	<input
		id="password"
		type="password"
		autocomplete={mode === 'signin' ? 'current-password' : 'new-password'}
		minlength="6"
		required
		bind:value={password}
	/>

	{#if error}<p class="msg error" role="alert">{error}</p>{/if}
	{#if notice}<p class="msg ok" role="status">{notice}</p>{/if}

	<div class="row" style="margin-top:16px">
		<button class="primary" type="submit" disabled={busy}>
			{busy ? 'Please wait…' : mode === 'signin' ? 'Sign in' : 'Create account'}
		</button>
		<button
			type="button"
			onclick={() => {
				mode = mode === 'signin' ? 'signup' : 'signin';
				error = notice = '';
			}}
		>
			{mode === 'signin' ? 'New here? Create an account' : 'Have an account? Sign in'}
		</button>
	</div>
</form>
