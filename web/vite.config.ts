import adapter from '@sveltejs/adapter-static';
import { sveltekit } from '@sveltejs/kit/vite';
import { defineConfig } from 'vite';

export default defineConfig({
	plugins: [
		sveltekit({
			compilerOptions: {
				// Force runes mode for the project, except for libraries. Can be removed in svelte 6.
				runes: ({ filename }) =>
					filename.split(/[/\\]/).includes('node_modules') ? undefined : true
			},
			// Client-only SPA: every page talks to Supabase directly (RLS does the
			// access control), so the build is plain static files; every path falls back to index.html (see static/_redirects).
			adapter: adapter({ fallback: 'index.html' })
		})
	]
});
