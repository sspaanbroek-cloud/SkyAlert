<script lang="ts">
	import SpotForm from '#lib/components/SpotForm.svelte';
	import NearbyWeather from '#lib/components/NearbyWeather.svelte';
	import UpcomingPasses from '#lib/components/UpcomingPasses.svelte';
	import RegularFlights from '#lib/components/RegularFlights.svelte';
	import { deleteSpot, describeError, getSpot, updateSpot, type Spot, type SpotInput } from '#lib/spots.ts';
	import { goto } from '$app/navigation';
	import { page } from '$app/state';

	const id = $derived(page.params.id as string);
	let spot: Spot | null | undefined = $state();
	let error = $state('');
	let deleting = $state(false);

	$effect(() => {
		spot = undefined;
		getSpot(id)
			.then((s) => (spot = s))
			.catch((e) => (error = describeError(e)));
	});

	async function save(input: SpotInput) {
		try {
			await updateSpot(id, input);
		} catch (e) {
			throw new Error(describeError(e));
		}
		await goto('/');
	}

	async function remove() {
		if (!spot || !confirm(`Delete "${spot.name}"? Its predicted passes and alerts are deleted too.`)) return;
		deleting = true;
		try {
			await deleteSpot(id);
			await goto('/');
		} catch (e) {
			error = describeError(e);
			deleting = false;
		}
	}
</script>

{#if error}
	<p class="msg error" role="alert">{error}</p>
{:else if spot === undefined}
	<p class="hint">Loading…</p>
{:else if spot === null}
	<h1>Spot not found</h1>
	<p><a href="/">Back to your spots</a></p>
{:else}
	<h1>{spot.name}</h1>
	<UpcomingPasses spotId={spot.id} timeZone={spot.time_zone} />
	<div style="height:12px"></div>
	<NearbyWeather spotId={spot.id} />
	<div style="height:12px"></div>
	<RegularFlights spotId={spot.id} />
	<h2 style="font-size:1.125rem;margin:24px 0 0">Edit spot</h2>
	{#key spot.id}
		<SpotForm initial={spot} submitLabel="Save changes" onsubmit={save} />
	{/key}
	<hr style="border:none;border-top:1px solid var(--border);margin:32px 0 16px" />
	<button class="danger" onclick={remove} disabled={deleting}>{deleting ? 'Deleting…' : 'Delete spot'}</button>
{/if}
