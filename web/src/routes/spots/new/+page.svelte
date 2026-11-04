<script lang="ts">
	import SpotForm from '#lib/components/SpotForm.svelte';
	import { createSpot, describeError, type SpotInput } from '#lib/spots.ts';
	import { goto } from '$app/navigation';

	async function save(input: SpotInput) {
		try {
			await createSpot(input);
		} catch (e) {
			throw new Error(describeError(e));
		}
		await goto('/');
	}
</script>

<h1>New shooting spot</h1>
<SpotForm submitLabel="Save spot" onsubmit={save} />
