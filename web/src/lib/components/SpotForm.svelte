<script lang="ts">
	import SpotMap from './SpotMap.svelte';
	import { lookupElevationFt } from '#lib/elevation.ts';
	import { formatLatLon, horizontalDistanceNm, isValidLatLon, type LatLon } from '#lib/geo.ts';
	import { SPOT_DEFAULTS, browserTimeZone, timeZoneOptions, type SpotInput } from '#lib/spots.ts';

	interface Props {
		initial?: Partial<SpotInput>;
		submitLabel: string;
		onsubmit: (input: SpotInput) => Promise<void>;
	}
	let { initial = {}, submitLabel, onsubmit }: Props = $props();

	// svelte-ignore state_referenced_locally -- form is seeded once from `initial`
	const seed = initial;
	let name = $state(seed.name ?? '');
	let point: LatLon | null = $state(
		seed.lat != null && seed.lon != null ? { lat: seed.lat, lon: seed.lon } : null
	);
	let elevationFt: number | null = $state(seed.elevation_ft ?? null);
	// 'saved' and 'manual' values are kept when the pin moves; 'lookup' values are refreshed.
	let elevationSource: 'none' | 'saved' | 'lookup' | 'manual' | 'failed' = $state(
		seed.elevation_ft != null ? 'saved' : 'none'
	);
	let radiusNm = $state(seed.search_radius_nm ?? SPOT_DEFAULTS.search_radius_nm);
	let minElevationDeg = $state(seed.min_elevation_deg ?? SPOT_DEFAULTS.min_elevation_deg);
	let timeZone = $state(seed.time_zone ?? browserTimeZone());
	let alertsEnabled = $state(seed.alerts_enabled ?? SPOT_DEFAULTS.alerts_enabled);
	let alertsMinRating: 'clear' | 'partial' = $state(seed.alerts_min_rating ?? SPOT_DEFAULTS.alerts_min_rating);
	let alertsLeadMin = $state(seed.alerts_lead_min ?? SPOT_DEFAULTS.alerts_lead_min);
	const zones = timeZoneOptions(seed.time_zone ?? browserTimeZone());
	let coordText = $state(
		seed.lat != null && seed.lon != null ? `${seed.lat.toFixed(5)}, ${seed.lon.toFixed(5)}` : ''
	);

	let busy = $state(false);
	let locating = $state(false);
	let lookingUp = $state(false);
	let error = $state('');
	let map: SpotMap | undefined = $state();
	let lookupCtl: AbortController | undefined;

	async function setPoint(p: LatLon, opts: { refocus?: boolean } = {}) {
		point = { lat: p.lat, lon: p.lon };
		coordText = `${p.lat.toFixed(5)}, ${p.lon.toFixed(5)}`;
		if (opts.refocus) queueMicrotask(() => map?.focus());
		if (elevationSource === 'manual') return;
		lookupCtl?.abort();
		lookupCtl = new AbortController();
		lookingUp = true;
		const ft = await lookupElevationFt(p, lookupCtl.signal);
		if (lookupCtl.signal.aborted) return;
		lookingUp = false;
		if (ft != null) {
			elevationFt = ft;
			elevationSource = 'lookup';
		} else if (elevationSource !== 'saved') {
			elevationSource = 'failed';
		}
	}

	function useMyLocation() {
		if (!('geolocation' in navigator)) {
			error = 'This browser cannot share your location. Tap the map instead.';
			return;
		}
		locating = true;
		error = '';
		navigator.geolocation.getCurrentPosition(
			(pos) => {
				locating = false;
				setPoint({ lat: pos.coords.latitude, lon: pos.coords.longitude }, { refocus: true });
			},
			(err) => {
				locating = false;
				error =
					err.code === err.PERMISSION_DENIED
						? 'Location permission was denied. Tap the map or type coordinates instead.'
						: 'Could not get your location. Tap the map or type coordinates instead.';
			},
			{ enableHighAccuracy: true, timeout: 15000 }
		);
	}

	function applyCoordText() {
		const m = coordText.match(/^\s*(-?\d+(?:\.\d+)?)\s*[,\s]\s*(-?\d+(?:\.\d+)?)\s*$/);
		const p = m ? { lat: Number(m[1]), lon: Number(m[2]) } : null;
		if (!p || !isValidLatLon(p)) {
			error = 'Enter coordinates as "latitude, longitude", for example 47.51340, -122.27120.';
			return;
		}
		error = '';
		setPoint(p, { refocus: true });
	}

	// Planning hint: where does the elevation-angle limit bite for a typical airliner?
	const cruiseHintNm = $derived(horizontalDistanceNm(35000, minElevationDeg, elevationFt ?? 0));

	async function submit(e: SubmitEvent) {
		e.preventDefault();
		error = '';
		if (!point) {
			error = 'Place your spot on the map first.';
			return;
		}
		if (elevationFt == null || !Number.isFinite(elevationFt)) {
			error = 'Enter the ground elevation of your spot in feet.';
			return;
		}
		busy = true;
		try {
			await onsubmit({
				name,
				lat: point.lat,
				lon: point.lon,
				elevation_ft: elevationFt,
				search_radius_nm: radiusNm,
				min_elevation_deg: minElevationDeg,
				time_zone: timeZone,
				alerts_enabled: alertsEnabled,
				alerts_min_rating: alertsMinRating,
				alerts_lead_min: alertsLeadMin
			});
		} catch (err) {
			error = (err as Error).message;
		} finally {
			busy = false;
		}
	}
</script>

<form onsubmit={submit} novalidate>
	<label for="name">Name</label>
	<input id="name" type="text" required maxlength="100" placeholder="e.g. Kubota Garden hill" bind:value={name} />

	<label for="coords">Location</label>
	<p class="hint" style="margin:0 0 8px">Tap the map to drop a pin, then drag it to fine-tune.</p>
	<SpotMap bind:this={map} value={point} {radiusNm} onchange={(p) => setPoint(p)} />
	<div class="row" style="margin-top:8px">
		<button type="button" onclick={useMyLocation} disabled={locating}>
			{locating ? 'Finding you…' : 'Use my location'}
		</button>
	</div>
	<div class="row coords">
		<input
			id="coords"
			type="text"
			inputmode="decimal"
			placeholder="latitude, longitude"
			bind:value={coordText}
			onkeydown={(e) => e.key === 'Enter' && (e.preventDefault(), applyCoordText())}
		/>
		<button type="button" onclick={applyCoordText}>Go</button>
	</div>
	{#if point}<p class="hint" data-testid="point">{formatLatLon(point)}</p>{/if}

	<label for="elev">Ground elevation (ft above sea level)</label>
	<input
		id="elev"
		type="number"
		inputmode="numeric"
		step="1"
		min="-1500"
		max="30000"
		bind:value={elevationFt}
		oninput={() => (elevationSource = 'manual')}
	/>
	<p class="hint" aria-live="polite">
		{#if lookingUp}Looking up elevation…
		{:else if elevationSource === 'lookup'}Looked up from terrain data. Change it if you shoot from a roof or tower.
		{:else if elevationSource === 'failed'}Couldn't look up elevation. Please type it in.
		{:else if elevationSource === 'manual'}Using the value you entered.
		{:else if elevationSource === 'none'}Filled in automatically when you place the pin.
		{/if}
	</p>

	<label for="radius">Search radius: {radiusNm} nm</label>
	<input id="radius" type="range" min="1" max="50" step="1" bind:value={radiusNm} />
	<p class="hint">How far from your spot an aircraft's closest point can be and still count as a pass.</p>

	<label for="minel">Lowest useful angle: {minElevationDeg}° above the horizon</label>
	<input id="minel" type="range" min="0" max="80" step="5" bind:value={minElevationDeg} />
	<p class="hint">
		Ignore aircraft lower in the sky than this (trees, buildings, haze).
		{#if Number.isFinite(cruiseHintNm)}
			An airliner at 35,000 ft is {minElevationDeg}° up when it's about {cruiseHintNm.toFixed(1)} nm away{cruiseHintNm >
			radiusNm
				? `, so your ${radiusNm} nm radius is the tighter limit for high traffic.`
				: '.'}
		{/if}
	</p>

	<label for="tz">Time zone</label>
	<select id="tz" bind:value={timeZone}>
		{#each zones as z (z)}<option value={z}>{z.replaceAll('_', ' ')}</option>{/each}
	</select>
	<p class="hint">Pass times and "usual" flight times for this spot are shown in this zone.</p>

	<fieldset class="alerts">
		<legend>Alerts</legend>
		<label class="check"><input type="checkbox" bind:checked={alertsEnabled} /> Alert me before good passes</label>
		{#if alertsEnabled}
			<label for="minrating">Which passes</label>
			<select id="minrating" bind:value={alertsMinRating}>
				<option value="clear">Clear view only</option>
				<option value="partial">Clear or partly visible</option>
			</select>
			<label for="lead">Minutes ahead</label>
			<input id="lead" type="number" inputmode="numeric" min="1" max="120" step="1" bind:value={alertsLeadMin} />
			<p class="hint">
				For live-tracked aircraft. Most are spotted 5 to 15 minutes out, so you'll often get the alert as soon as one is
				found. Turn on notifications on the home page for each device.
			</p>
		{/if}
	</fieldset>

	{#if error}<p class="msg error" role="alert">{error}</p>{/if}

	<div class="row" style="margin-top:20px">
		<button class="primary" type="submit" disabled={busy}>{busy ? 'Saving…' : submitLabel}</button>
		<a class="button" href="/">Cancel</a>
	</div>
</form>

<style>
	.alerts {
		border: 1px solid var(--border);
		border-radius: var(--radius);
		padding: 4px 12px 12px;
		margin: 20px 0 0;
	}
	.alerts legend {
		font-weight: 600;
		padding: 0 4px;
	}
	.check {
		display: flex;
		align-items: center;
		gap: 8px;
		font-weight: 400;
		margin-top: 8px;
	}
	.check input {
		width: 20px;
		height: 20px;
		accent-color: var(--accent);
	}
	.coords {
		margin-top: 8px;
		flex-wrap: nowrap;
	}
	.coords input {
		flex: 1;
		min-width: 0;
	}
</style>
