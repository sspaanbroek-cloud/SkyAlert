<script lang="ts">
	import { auth } from '#lib/auth.svelte.ts';
	import { formatPhone, normalizePhone, SMS_CONSENT_TEXT } from '#lib/phone.ts';
	import { getPrefs, setSmsEnabled, type NotificationPref } from '#lib/prefs.ts';
	import { supabase } from '#lib/supabase.ts';

	let prefs: NotificationPref | null = $state(null);
	let phoneInput = $state('');
	let pendingPhone = $state('');
	let code = $state('');
	let busy = $state(false);
	let error = $state('');
	let notice = $state('');

	const user = $derived(auth.session?.user);
	const verifiedPhone = $derived(user?.phone && user.phone_confirmed_at ? user.phone : null);

	$effect(() => {
		getPrefs()
			.then((p) => (prefs = p))
			.catch((e) => (error = (e as Error).message));
	});

	async function sendCode(e: SubmitEvent) {
		e.preventDefault();
		error = notice = '';
		const phone = normalizePhone(phoneInput);
		if (!phone) {
			error = 'Enter a mobile number, with the country code if it is outside the US (for example +44 7700 900123).';
			return;
		}
		busy = true;
		const { error: err } = await supabase.auth.updateUser({ phone });
		busy = false;
		if (err) {
			error = err.message;
			return;
		}
		pendingPhone = phone;
		notice = `We texted a code to ${formatPhone(phone)}.`;
	}

	async function verify(e: SubmitEvent) {
		e.preventDefault();
		error = '';
		busy = true;
		const { error: err } = await supabase.auth.verifyOtp({ phone: pendingPhone, token: code.trim(), type: 'phone_change' });
		busy = false;
		if (err) {
			error = err.message;
			return;
		}
		pendingPhone = '';
		code = '';
		notice = 'Number verified.';
	}

	async function toggle(e: Event) {
		const on = (e.currentTarget as HTMLInputElement).checked;
		error = '';
		try {
			await setSmsEnabled(on);
			prefs = await getPrefs();
		} catch (err) {
			error = (err as Error).message;
		}
	}
</script>

<div class="sms" aria-labelledby="sms-heading">
	<h3 id="sms-heading">Text messages</h3>
	{#if verifiedPhone}
		<p class="hint" style="margin-top:0">Texts go to {formatPhone(verifiedPhone)}.</p>
		{#if prefs}
			<label class="check">
				<input type="checkbox" checked={prefs.sms_enabled && !prefs.sms_opted_out_at} onchange={toggle} />
				Send my alerts and reminders by text
			</label>
			<p class="hint">{SMS_CONSENT_TEXT}</p>
			{#if prefs.sms_opted_out_at}
				<p class="msg error">You replied STOP, so texts are paused. Tick the box to start them again.</p>
			{/if}
		{/if}
	{:else if pendingPhone}
		<form onsubmit={verify}>
			<label for="sms-code">Code from the text</label>
			<div class="row nowrap">
				<input id="sms-code" type="text" inputmode="numeric" autocomplete="one-time-code" maxlength="10" bind:value={code} />
				<button class="primary" type="submit" disabled={busy || !code.trim()}>Verify</button>
			</div>
		</form>
	{:else}
		<p class="hint" style="margin-top:0">Get alerts by text as well as, or instead of, notifications. Add your mobile number first.</p>
		<form onsubmit={sendCode}>
			<label for="sms-phone">Mobile number</label>
			<div class="row nowrap">
				<input id="sms-phone" type="tel" autocomplete="tel" placeholder="(415) 555-0101" bind:value={phoneInput} />
				<button type="submit" disabled={busy}>Text me a code</button>
			</div>
		</form>
	{/if}
	{#if notice}<p class="msg ok" role="status">{notice}</p>{/if}
	{#if error}<p class="msg error" role="alert">{error}</p>{/if}
</div>

<style>
	.sms {
		border-top: 1px solid var(--border);
		margin-top: 16px;
		padding-top: 12px;
	}
	h3 {
		font-size: 1rem;
		margin: 0 0 6px;
	}
	.nowrap {
		flex-wrap: nowrap;
	}
	.nowrap input {
		flex: 1;
		min-width: 0;
	}
	.check {
		display: flex;
		align-items: center;
		gap: 8px;
		font-weight: 400;
		margin-top: 4px;
	}
	.check input {
		width: 20px;
		height: 20px;
		accent-color: var(--accent);
	}
</style>
