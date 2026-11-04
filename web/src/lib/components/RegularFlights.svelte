<script lang="ts">
	import { formatFt } from '#lib/geo.ts';
	import { formatDays, formatLocalTime, listRegularFlights, type RegularFlight } from '#lib/recurring.ts';
	import { compass } from '#lib/weather.ts';

	let { spotId }: { spotId: string } = $props();
	let flights: RegularFlight[] | null = $state(null);
	let error = $state('');

	$effect(() => {
		flights = null;
		listRegularFlights(spotId)
			.then((f) => (flights = f))
			.catch((e) => (error = (e as Error).message));
	});

	function where(f: RegularFlight): string {
		return [
			f.typical_altitude_ft != null ? formatFt(f.typical_altitude_ft) : null,
			f.typical_azimuth_deg != null ? `look ${compass(Number(f.typical_azimuth_deg))}` : null,
			f.typical_elevation_deg != null ? `${Math.round(Number(f.typical_elevation_deg))}° up` : null
		]
			.filter(Boolean)
			.join(', ');
	}
</script>

<section class="card" aria-labelledby="regulars-heading">
	<h2 id="regulars-heading">Regulars over this spot</h2>
	{#if error}
		<p class="msg error" role="alert">Couldn't load regular flights: {error}</p>
	{:else if flights === null}
		<p class="hint">Loading…</p>
	{:else if flights.length === 0}
		<p class="hint">
			None yet. Flights seen passing here at about the same time on 3 or more days show up here, and their next
			passes are added to "Coming overhead".
		</p>
	{:else}
		<ul>
			{#each flights as f (f.id)}
				<li>
					<div class="head">
						<strong>{f.callsign}</strong>
						<span>about {formatLocalTime(f.typical_local_time)}, {formatDays(f.days_of_week)}</span>
					</div>
					{#if where(f)}<p class="hint">{where(f)}</p>{/if}
					<p class="hint">
						Seen {f.observation_count} {f.observation_count === 1 ? 'time' : 'times'} on {f.distinct_days} days{f.time_spread_min !=
						null
							? `, usually within ${Math.max(1, f.time_spread_min)} min of that time`
							: ''}
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
		gap: 10px;
	}
	li + li {
		border-top: 1px solid var(--border);
		padding-top: 10px;
	}
	.head {
		display: flex;
		gap: 8px;
		flex-wrap: wrap;
		align-items: baseline;
	}
	li .hint {
		margin: 2px 0 0;
	}
</style>
