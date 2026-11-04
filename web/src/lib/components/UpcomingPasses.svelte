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

	let { spotId, timeZone }: { spotId: string; timeZone?: string } = $props();

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
	li .hint {
		margin: 2px 0 0;
	}
</style>
