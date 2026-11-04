<script lang="ts">
	import { formatFt } from '#lib/geo.ts';
	import {
		clockTime,
		confidenceLabel,
		flightLabel,
		listUpcomingPasses,
		lookLabel,
		whenLabel,
		type Pass
	} from '#lib/passes.ts';

	let { spotId }: { spotId: string } = $props();

	const REFRESH_MS = 30_000;
	let passes: Pass[] | null = $state(null);
	let error = $state('');
	let now = $state(new Date());

	async function load() {
		try {
			passes = await listUpcomingPasses(spotId);
			error = '';
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
			minutes ahead. This list refreshes by itself.
		</p>
	{:else}
		<ul>
			{#each passes as p (p.id)}
				{@const when = whenLabel(p.closest_approach_at, now)}
				{@const look = lookLabel(p)}
				{@const conf = confidenceLabel(p.confidence)}
				<li class:now={when === 'Passing now'} class:past={when === 'Just passed'}>
					<div class="head">
						<strong>{flightLabel(p)}</strong>
						<span class="when">{when}</span>
						<span class="hint">{clockTime(p.closest_approach_at)}</span>
					</div>
					<p class="detail">
						{[p.altitude_ft != null ? formatFt(p.altitude_ft) : null, `passes ${p.closest_distance_nm.toFixed(1)} nm away`]
							.filter(Boolean)
							.join(', ')}
					</p>
					{#if look}<p class="detail">{look}</p>{/if}
					<p class="hint">
						{p.basis === 'live_adsb' ? 'Live tracking' : 'Filed flight plan'}{#if conf}&ensp;·&ensp;{conf} confidence{/if}
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
	li.now .when {
		color: var(--ok-text);
	}
	li.past {
		opacity: 0.65;
	}
	.detail {
		margin: 2px 0 0;
	}
	li .hint {
		margin: 2px 0 0;
	}
</style>
