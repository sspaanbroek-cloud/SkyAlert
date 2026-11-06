import adapter from '@sveltejs/adapter-static';
import { sveltekit } from '@sveltejs/kit/vite';
import { Buffer } from 'node:buffer';
import process from 'node:process';
import { defineConfig, loadEnv } from 'vite';

/**
 * Everything named VITE_* is built into the public website, where anyone can
 * read it. Refuse to build if a secret has been put in one of those settings
 * by mistake (a database connection string, an access token, a secret key,
 * the private notification key), so it is never published.
 */
function refuseSecretsInPublicSettings(mode: string) {
	const env = { ...loadEnv(mode, process.cwd(), 'VITE_'), ...process.env };
	const problems: string[] = [];
	const url = env.VITE_SUPABASE_URL ?? '';
	const key = env.VITE_SUPABASE_ANON_KEY ?? '';
	const vapid = env.VITE_VAPID_PUBLIC_KEY ?? '';
	if (/^postgres(ql)?:\/\//i.test(url) || /@/.test(url)) {
		problems.push(
			'VITE_SUPABASE_URL contains a database connection string, which includes your database password. It must be https://<your project ID>.supabase.co.'
		);
	}
	if (/^(sbp_|sb_secret_)/.test(key) || /service_role/.test(atobSafe(key.split('.')[1] ?? ''))) {
		problems.push(
			'VITE_SUPABASE_ANON_KEY contains a secret key (an access token or secret/service key). It must be the publishable key (sb_publishable_...) or the legacy anon key.'
		);
	}
	if (vapid && !/^B[A-Za-z0-9_-]{86}$/.test(vapid)) {
		problems.push('VITE_VAPID_PUBLIC_KEY is not a public notification key (87 characters starting with B). Never put the private key here.');
	}
	if (problems.length) {
		throw new Error(
			'Refusing to build: these settings would publish a secret on the website.\n- ' +
				problems.join('\n- ') +
				'\nFix them in Netlify (Project configuration > Environment variables), then replace any secret that was published before.'
		);
	}
}

function atobSafe(s: string): string {
	try {
		return Buffer.from(s, 'base64').toString('utf8');
	} catch {
		return '';
	}
}

export default defineConfig(({ mode }) => {
	refuseSecretsInPublicSettings(mode);
	return {
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
};
});
