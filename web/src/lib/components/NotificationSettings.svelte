<script lang="ts">
	import { disablePush, enablePush, pushState, type PushState } from '#lib/push.ts';
	import SmsSettings from './SmsSettings.svelte';

	let status: PushState | 'loading' = $state('loading');
	let busy = $state(false);
	let error = $state('');

	$effect(() => {
		pushState()
			.then((s) => (status = s))
			.catch(() => (status = 'unsupported'));
	});

	async function toggle() {
		busy = true;
		error = '';
		try {
			status = status === 'on' ? await disablePush() : await enablePush();
		} catch (e) {
			error = (e as Error).message;
		} finally {
			busy = false;
		}
	}
</script>

<section class="card" aria-labelledby="notif-heading">
	<h2 id="notif-heading">Notifications</h2>
	<h3 class="sub">On this device</h3>
	{#if status === 'loading'}
		<p class="hint">Checking…</p>
	{:else if status === 'no-key'}
		<p class="hint">Notifications aren't set up on this server yet (missing VAPID key).</p>
	{:else if status === 'ios-home-screen'}
		<p class="hint">
			On iPhone and iPad, add SkyAlert to your Home Screen first (Share, then "Add to Home Screen"), open it from
			there, and turn notifications on.
		</p>
	{:else if status === 'unsupported'}
		<p class="hint">This browser can't receive web notifications.</p>
	{:else if status === 'denied'}
		<p class="hint">Notifications are blocked for SkyAlert. Allow them in your browser's site settings, then reload.</p>
	{:else}
		<p class="hint" style="margin-top:0">
			{status === 'on'
				? 'On. You\'ll get alerts on this device for spots with alerts turned on, and for passes you set reminders for.'
				: 'Turn on to get alerts before good passes on this device.'}
		</p>
		<button class={status === 'on' ? '' : 'primary'} onclick={toggle} disabled={busy}>
			{busy ? 'Please wait…' : status === 'on' ? 'Turn off on this device' : 'Turn on notifications'}
		</button>
	{/if}
	{#if error}<p class="msg error" role="alert">{error}</p>{/if}
	<SmsSettings />
</section>

<style>
	h2 {
		font-size: 1.125rem;
		margin: 0 0 8px;
	}
	.sub {
		font-size: 1rem;
		margin: 0 0 6px;
	}
</style>
