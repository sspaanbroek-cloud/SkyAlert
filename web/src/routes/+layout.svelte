<script lang="ts">
	import '../app.css';
	import favicon from '#lib/assets/favicon.svg';
	import { auth } from '#lib/auth.svelte.ts';
	import { configError, supabase } from '#lib/supabase.ts';
	import { goto } from '$app/navigation';
	import { page } from '$app/state';
	import type { LayoutProps } from './$types';

	let { children }: LayoutProps = $props();

	const isLogin = $derived(page.url.pathname === '/login');

	// Simple guard: everything except /login needs a session.
	$effect(() => {
		if (!auth.ready || configError) return;
		if (!auth.session && !isLogin) goto('/login', { replaceState: true });
		if (auth.session && isLogin) goto('/', { replaceState: true });
	});

	async function signOut() {
		await supabase.auth.signOut();
	}
</script>

<svelte:head>
	<link rel="icon" href={favicon} />
	<title>SkyAlert</title>
</svelte:head>

<header>
	<a class="brand" href="/">SkyAlert</a>
	{#if auth.session}
		<span class="who">{auth.session.user.email}</span>
		<button onclick={signOut}>Sign out</button>
	{/if}
</header>

<main>
	{#if configError}
		<div class="card" role="alert">
			<h1 style="margin-top:0">SkyAlert isn't set up yet</h1>
			<p>{configError}</p>
		</div>
	{:else if !auth.ready}
		<p class="hint">Loading…</p>
	{:else if auth.session || isLogin}
		{@render children()}
	{/if}
</main>

<style>
	header {
		display: flex;
		align-items: center;
		gap: 12px;
		max-width: 640px;
		margin: 0 auto;
		padding: 8px 16px;
		border-bottom: 1px solid var(--border);
	}
	.brand {
		font-weight: 700;
		font-size: 1.125rem;
		color: var(--text);
		text-decoration: none;
		margin-right: auto;
	}
	.who {
		color: var(--muted);
		font-size: 0.875rem;
		overflow: hidden;
		text-overflow: ellipsis;
		white-space: nowrap;
		min-width: 0;
	}
	header button {
		min-height: 36px;
		padding: 6px 12px;
		flex-shrink: 0;
	}
</style>
