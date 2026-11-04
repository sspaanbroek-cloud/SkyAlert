<script lang="ts">
	import {
		STALE_AFTER_MIN,
		compass,
		formatAge,
		formatVisibility,
		getNearbyWeather,
		type StationWeather
	} from '#lib/weather.ts';

	let { spotId }: { spotId: string } = $props();

	let stations: StationWeather[] | null = $state(null);
	let error = $state('');

	$effect(() => {
		stations = null;
		error = '';
		getNearbyWeather(spotId)
			.then((s) => (stations = s))
			.catch((e) => (error = (e as Error).message));
	});
</script>

<section class="card" aria-labelledby="sky-heading">
	<h2 id="sky-heading">Sky near this spot</h2>
	{#if error}
		<p class="msg error" role="alert">Couldn't load weather: {error}</p>
	{:else if stations === null}
		<p class="hint">Loading weather…</p>
	{:else if stations.length === 0}
		<p class="hint">
			No weather reports near here yet. Reports from nearby airports are collected every 10 minutes after you save a
			spot.
		</p>
	{:else}
		<ul>
			{#each stations as w (w.station)}
				{@const vis = formatVisibility(w)}
				<li>
					<div class="head">
						<strong>{w.station}</strong>
						<span class="hint">{w.distance_nm} nm {compass(w.bearing_deg)}</span>
						{#if w.flight_category}<span class="cat cat-{w.flight_category.toLowerCase()}">{w.flight_category}</span>{/if}
					</div>
					<p class="summary">{w.sky_summary}</p>
					<p class="hint">
						<span class:stale={w.age_min > STALE_AFTER_MIN}>
							Reported {formatAge(w.age_min)}{w.age_min > STALE_AFTER_MIN ? ' (old report)' : ''}
						</span>{#if vis}&ensp;·&ensp;{vis}{/if}{#if w.wx_string}&ensp;·&ensp;{w.wx_string}{/if}
					</p>
					<details>
						<summary>Raw report</summary>
						<code>{w.raw_text}</code>
						{#if w.station_name}<p class="hint">{w.station_name}, field elevation {w.station_elevation_ft.toLocaleString('en-US')} ft</p>{/if}
					</details>
				</li>
			{/each}
		</ul>
		<p class="hint">
			Cloud heights are above each airport's ground level. A report describes the airport, not your exact spot.
		</p>
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
	.summary {
		margin: 4px 0 0;
	}
	li .hint {
		margin: 2px 0 0;
	}
	.stale {
		color: var(--danger);
	}
	.cat {
		font-size: 0.75rem;
		font-weight: 700;
		padding: 1px 6px;
		border-radius: 4px;
		border: 1px solid currentColor;
	}
	.cat-vfr {
		color: var(--ok-text);
	}
	.cat-mvfr {
		color: var(--accent);
	}
	.cat-ifr,
	.cat-lifr {
		color: var(--danger);
	}
	details {
		margin-top: 4px;
		font-size: 0.875rem;
	}
	summary {
		cursor: pointer;
		color: var(--muted);
	}
	code {
		display: block;
		margin-top: 4px;
		padding: 8px;
		border-radius: 6px;
		background: var(--bg);
		overflow-wrap: anywhere;
		font-size: 0.8125rem;
	}
</style>
