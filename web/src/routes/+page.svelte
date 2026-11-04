<script lang="ts">
	import { describeError, listSpots, type Spot } from '#lib/spots.ts';
	import { formatFt, formatLatLon } from '#lib/geo.ts';
	import NotificationSettings from '#lib/components/NotificationSettings.svelte';

	let spots: Spot[] | null = $state(null);
	let error = $state('');

	$effect(() => {
		listSpots()
			.then((s) => (spots = s))
			.catch((e) => (error = describeError(e)));
	});
</script>

<div class="row" style="justify-content:space-between">
	<h1>Your shooting spots</h1>
	<a class="button primary" href="/spots/new">Add spot</a>
</div>

{#if error}
	<p class="msg error" role="alert">{error}</p>
{:else if spots === null}
	<p class="hint">Loading spots…</p>
{:else if spots.length === 0}
	<div class="card">
		<p style="margin-top:0"><strong>No spots yet.</strong></p>
		<p class="hint">Add the place you shoot from. We'll watch the sky within your chosen radius and tell you when aircraft will pass, and whether cloud will hide them.</p>
	</div>
{:else}
	<ul class="spots">
		{#each spots as s (s.id)}
			<li>
				<a class="card spot" href="/spots/{s.id}">
					<strong>{s.name}</strong>
					<span class="hint">{formatLatLon(s)} · {formatFt(s.elevation_ft)}</span>
					<span class="hint">Within {s.search_radius_nm} nm, at least {s.min_elevation_deg}° above the horizon</span>
					{#if s.alerts_enabled}<span class="hint">Alerts on: {s.alerts_min_rating === 'clear' ? 'clear views' : 'clear or partly visible'}, {s.alerts_lead_min} min ahead</span>{/if}
				</a>
			</li>
		{/each}
	</ul>
{/if}

<div style="height:16px"></div>
<NotificationSettings />

<style>
	.spots {
		list-style: none;
		padding: 0;
		margin: 0;
		display: grid;
		gap: 8px;
	}
	.spot {
		display: grid;
		gap: 2px;
		color: var(--text);
		text-decoration: none;
	}
	.spot .hint {
		margin: 0;
	}
</style>
