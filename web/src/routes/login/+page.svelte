<script lang="ts">
	import { formatPhone, normalizePhone } from '#lib/phone.ts';
	import { supabase } from '#lib/supabase.ts';

	let method: 'email' | 'phone' = $state('email');
	let mode: 'signin' | 'signup' = $state('signin');
	let email = $state('');
	let password = $state('');
	let phoneInput = $state('');
	let codeSentTo = $state('');
	let code = $state('');
	let busy = $state(false);
	let error = $state('');
	let notice = $state('');

	function reset() {
		error = notice = '';
	}

	async function submitEmail(e: SubmitEvent) {
		e.preventDefault();
		busy = true;
		reset();
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

	async function sendCode(e: SubmitEvent) {
		e.preventDefault();
		reset();
		const phone = normalizePhone(phoneInput);
		if (!phone) {
			error = 'Enter a mobile number, with the country code if it is outside the US (for example +44 7700 900123).';
			return;
		}
		busy = true;
		const { error: err } = await supabase.auth.signInWithOtp({ phone });
		busy = false;
		if (err) {
			error = err.message;
			return;
		}
		codeSentTo = phone;
		notice = `We texted a code to ${formatPhone(phone)}. It works for a few minutes.`;
	}

	async function verifyCode(e: SubmitEvent) {
		e.preventDefault();
		reset();
		busy = true;
		const { error: err } = await supabase.auth.verifyOtp({ phone: codeSentTo, token: code.trim(), type: 'sms' });
		busy = false;
		if (err) error = err.message;
		// on success the layout redirects
	}
</script>

<h1>{method === 'phone' ? 'Sign in with your phone' : mode === 'signin' ? 'Sign in' : 'Create an account'}</h1>
<p class="hint">Save your shooting spots and see which aircraft will pass overhead, and whether cloud will hide them.</p>

<div class="tabs" role="tablist" aria-label="How to sign in">
	<button role="tab" aria-selected={method === 'email'} class:active={method === 'email'}
		onclick={() => ((method = 'email'), reset())}>Email</button>
	<button role="tab" aria-selected={method === 'phone'} class:active={method === 'phone'}
		onclick={() => ((method = 'phone'), reset())}>Phone (text a code)</button>
</div>

{#if method === 'email'}
	<form class="card" onsubmit={submitEmail}>
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
			<button type="button" onclick={() => ((mode = mode === 'signin' ? 'signup' : 'signin'), reset())}>
				{mode === 'signin' ? 'New here? Create an account' : 'Have an account? Sign in'}
			</button>
		</div>
	</form>
{:else if !codeSentTo}
	<form class="card" onsubmit={sendCode}>
		<label for="phone">Mobile number</label>
		<input id="phone" type="tel" autocomplete="tel" placeholder="(415) 555-0101" required bind:value={phoneInput} />
		<p class="hint">New here? Same steps: your account is made the first time you sign in. Message and data rates may apply.</p>
		{#if error}<p class="msg error" role="alert">{error}</p>{/if}
		<div class="row" style="margin-top:16px">
			<button class="primary" type="submit" disabled={busy}>{busy ? 'Please wait…' : 'Text me a code'}</button>
		</div>
	</form>
{:else}
	<form class="card" onsubmit={verifyCode}>
		{#if notice}<p class="msg ok" role="status" style="margin-top:0">{notice}</p>{/if}
		<label for="code">Code</label>
		<input id="code" type="text" inputmode="numeric" autocomplete="one-time-code" maxlength="10" required bind:value={code} />
		{#if error}<p class="msg error" role="alert">{error}</p>{/if}
		<div class="row" style="margin-top:16px">
			<button class="primary" type="submit" disabled={busy || !code.trim()}>{busy ? 'Checking…' : 'Sign in'}</button>
			<button type="button" onclick={() => ((codeSentTo = ''), (code = ''), reset())}>Use a different number</button>
		</div>
	</form>
{/if}

<style>
	.tabs {
		display: flex;
		gap: 8px;
		margin: 12px 0;
	}
	.tabs button {
		flex: 1;
	}
	.tabs button.active {
		border-color: var(--accent);
		color: var(--accent);
	}
</style>
