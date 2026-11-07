<script lang="ts">
	// Small lightning-bolt mark; `label` is read out by screen readers and shown on hover/long-press.
	let { label }: { label: string } = $props();
</script>

<span class="bolt" role="img" aria-label={label} title={label}>
	<svg viewBox="0 0 24 24" width="16" height="16" aria-hidden="true">
		<path d="M13 2 4 14h7l-1 8 9-12h-7l1-8z" fill="currentColor" />
	</svg>
</span>

<style>
	.bolt {
		display: inline-flex;
		vertical-align: -2px;
		margin-left: 4px;
		color: var(--warn-text);
		cursor: help;
	}
</style>
