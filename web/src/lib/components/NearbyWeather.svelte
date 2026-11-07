<script lang="ts">
	import {
		STALE_AFTER_MIN,
		compass,
		formatAge,
		formatVisibility,
		getNearbyForecast,
		getNearbyWeather,
		type ForecastPeriod,
		type StationWeather
	} from '#lib/weather.ts';
	import { describeLightning, describeWeather } from '#lib/wx.ts';
	import { periodLabel, periodText } from '#lib/forecast.ts';
	import LightningBolt from './LightningBolt.svelte';

	let { spotId, timeZone }: { spotId: string; timeZone?: string } = $props();

	let stations: StationWeather[] | null = $state(null);
	let forecast: ForecastPeriod[] | null = $state(null);
	let error = $state('');
	const now = new Date();

	$effect(() => {
		stations = null;
		forecast = null;
		error = '';
		getNearbyWeather(spotId)
			.then((s) => (stations = s))
			.catch((e) => (error = (e as Error).message));
		getNearbyForecast(spotId)
			.then((f) => (forecast = f))
			.catch(() => (forecast = []));
	});

	const tafAge = (min: number) => (min < 90 ? `${min} min ago` : `${Math.round(min / 60)} h ago`);
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
					<p class="summary">
						{w.sky_summary}{#if w.lightning_remark}<LightningBolt label={describeLightning(w.lightning_remark) ?? 'Lightning reported'} />{/if}
					</p>
					<p class="hint">
						<span class:stale={w.age_min > STALE_AFTER_MIN}>
							Reported {formatAge(w.age_min)}{w.age_min > STALE_AFTER_MIN ? ' (old report)' : ''}
						</span>{#if vis}&ensp;·&ensp;{vis}{/if}{#if w.wx_string}&ensp;·&ensp;{describeWeather(w.wx_string)}{/if}
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

	{#if forecast && forecast.length}
		{@const f = forecast[0]}
		<h3 class="forecast-heading">Forecast</h3>
		<p class="hint" style="margin-top:0">
			{f.station} airport forecast, {f.distance_nm} nm {compass(f.bearing_deg)}, issued {tafAge(f.issued_age_min)}
		</p>
		<ul class="forecast">
			{#each forecast as p (p.seq)}
				<li class:temp={p.change_type === 'TEMPO' || p.change_type === 'PROB'}>
					<span class="when">{periodLabel(p, now, timeZone)}</span>
					<span>
						{periodText(p)}{#if p.thunder}<LightningBolt label="Thunderstorms forecast" />{/if}
					</span>
				</li>
			{/each}
		</ul>
		<details>
			<summary>Raw forecast</summary>
			<code>{f.raw_text}</code>
		</details>
	{:else if forecast && stations?.length}
		<p class="hint">No airport forecast (TAF) within 40 nm; smaller airports often don't issue one.</p>
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
	.forecast-heading {
		font-size: 1rem;
		margin: 16px 0 2px;
		padding-top: 12px;
		border-top: 1px solid var(--border);
	}
	.forecast {
		gap: 8px;
		margin-top: 8px;
	}
	.forecast li {
		display: grid;
		gap: 0;
		border: none;
		padding: 0;
	}
	.forecast li + li {
		border-top: none;
		padding-top: 0;
	}
	.forecast .when {
		font-size: 0.875rem;
		font-weight: 600;
		color: var(--muted);
	}
	.forecast li.temp {
		padding-left: 10px;
		border-left: 3px solid var(--border);
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
