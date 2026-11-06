<script lang="ts">
	import {
		BASIS_LABEL,
		RATING_LABEL,
		headline,
		weatherSource,
		confidenceLabel,
		listUpcomingPasses,
		lookLabel,
		whenLabel,
		type Pass
	} from '#lib/passes.ts';

	import { cancelReminder, pendingAlerts, remindMe } from '#lib/alerts.ts';
	import { notificationsGranted } from '#lib/push.ts';
	import { getPrefs } from '#lib/prefs.ts';

	let { spotId, timeZone, leadMin = 10 }: { spotId: string; timeZone?: string; leadMin?: number } = $props();
	let alerts: Map<number, { manual: boolean; notify_at: string }> = $state(new Map());
	let canNotify = $state(false);

	const REFRESH_MS = 30_000;
	let passes: Pass[] | null = $state(null);
	let error = $state('');
	let now = $state(new Date());

	async function load() {
		try {
			const [p, a, prefs] = await Promise.all([
				listUpcomingPasses(spotId),
				pendingAlerts(spotId),
				getPrefs().catch(() => null)
			]);
			[passes, alerts] = [p, a];
			canNotify = notificationsGranted() || Boolean(prefs?.sms_enabled && !prefs.sms_opted_out_at);
			error = '';
		} catch (e) {
			error = (e as Error).message;
		}
	}

	async function toggleReminder(p: Pass) {
		try {
			if (alerts.has(p.id)) await cancelReminder(spotId, p.id);
			else await remindMe(spotId, p.id, p.closest_approach_at, leadMin);
			alerts = await pendingAlerts(spotId);
		} catch (e) {
			error = (e as Error).message;
		}
	}

	$effect(() => {
		passes = null;
		load();
		const refresh = setInterval(() => document.visibilityState === 'visible' && load(), REFRESH_MS);
		const tick = setInterval(() => (now = new Date()), 10_000);
		const onVisible = () => document.visibilityState === 'visible' && load();
		document.addEventListener('visibilitychange', onVisible);
		return () => {
			clearInterval(refresh);
			clearInterval(tick);
			document.removeEventListener('visibilitychange', onVisible);
		};
	});
</script>

<section class="card" aria-labelledby="passes-heading">
	<h2 id="passes-heading">Coming overhead</h2>
	{#if error}
		<p class="msg error" role="alert">Couldn't load passes: {error}</p>
	{:else if passes === null}
		<p class="hint">Loading…</p>
	{:else if passes.length === 0}
		<p class="hint">
			Nothing predicted right now. Live tracking looks for aircraft heading within your search radius, usually 5 to 15
			minutes ahead, and flights seen here regularly appear up to 36 hours ahead. This list refreshes by itself.
		</p>
	{:else}
		<ul>
			{#each passes as p (p.id)}
				{@const when = whenLabel(p.closest_approach_at, now)}
				{@const look = lookLabel(p)}
				{@const conf = confidenceLabel(p.confidence)}
				{@const a = p.assessment}
				<li class:now={when === 'Passing now'} class:past={when === 'Just passed'}>
					<div class="head">
						<span class="rating rating-{a?.rating ?? 'unknown'}">{RATING_LABEL[a?.rating ?? 'unknown']}</span>
						<span class="when">{when}</span>
					</div>
					<p class="detail"><strong>{headline(p, timeZone, now)}</strong></p>
					{#if a}
						<p class="detail">{a.explanation}</p>
					{:else}
						<p class="detail hint">Checking the weather for this pass…</p>
					{/if}
					<p class="detail">{[look, `${p.closest_distance_nm.toFixed(1)} nm from you`].filter(Boolean).join(', ')}</p>
					{#if when !== 'Just passed' && when !== 'Passing now'}
						<div class="remind">
							{#if alerts.has(p.id)}
								<button class="small" onclick={() => toggleReminder(p)} aria-pressed="true">
									{alerts.get(p.id)?.manual ? 'Reminder set' : 'Alert queued'} · cancel
								</button>
							{:else}
								<button class="small" onclick={() => toggleReminder(p)} disabled={!canNotify}
									title={canNotify ? '' : 'Turn on notifications or texts on the home page first'}>Remind me</button>
								{#if !canNotify}<span class="hint">Turn on notifications or texts on the home page to use reminders.</span>{/if}
							{/if}
						</div>
					{/if}
					<p class="hint">
						{BASIS_LABEL[p.basis]}{#if conf}&ensp;·&ensp;{conf} confidence{/if}{#if a && weatherSource(a)}&ensp;·&ensp;{weatherSource(a)}{/if}
					</p>
				</li>
			{/each}
		</ul>
	{/if}
</section>

<style>
	h2 {
		font-size: 1.125rem;
		margin: 0 0 8px;
	}
	ul {
		list-style: none;
		margin: 0;
		padding: 0;
		display: grid;
		gap: 12px;
	}
	li + li {
		border-top: 1px solid var(--border);
		padding-top: 12px;
	}
	.head {
		display: flex;
		align-items: baseline;
		gap: 8px;
		flex-wrap: wrap;
	}
	.when {
		font-weight: 600;
		color: var(--accent);
	}
	.rating {
		font-size: 0.8125rem;
		font-weight: 700;
		padding: 2px 8px;
		border-radius: 999px;
	}
	.rating-clear {
		background: var(--ok-bg);
		color: var(--ok-text);
	}
	.rating-partial {
		background: var(--warn-bg);
		color: var(--warn-text);
	}
	.rating-hidden {
		background: var(--err-bg);
		color: var(--danger);
	}
	.rating-unknown {
		background: var(--bg);
		color: var(--muted);
		border: 1px solid var(--border);
	}
	li.now .when {
		color: var(--ok-text);
	}
	li.past {
		opacity: 0.65;
	}
	.detail {
		margin: 2px 0 0;
	}
	.remind {
		display: flex;
		align-items: center;
		gap: 8px;
		flex-wrap: wrap;
		margin-top: 6px;
	}
	.remind .hint {
		margin: 0;
	}
	button.small {
		min-height: 36px;
		padding: 6px 12px;
		font-size: 0.875rem;
	}
	li .hint {
		margin: 2px 0 0;
	}
</style>
