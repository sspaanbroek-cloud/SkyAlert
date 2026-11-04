import { defineConfig, devices } from '@playwright/test';
import { existsSync } from 'node:fs';

// Use a preinstalled Chromium when present (CI/sandbox), else Playwright's own.
const executablePath = process.env.PW_CHROMIUM ?? (existsSync('/opt/pw-browsers/chromium') ? '/opt/pw-browsers/chromium' : undefined);

export default defineConfig({
	testDir: 'tests',
	webServer: {
		command: 'npm run build && npx vite preview --port 4173 --strictPort',
		port: 4173,
		reuseExistingServer: !process.env.CI,
		env: {
			VITE_SUPABASE_URL: 'http://supabase.test',
			VITE_SUPABASE_ANON_KEY: 'test-anon-key',
			VITE_VAPID_PUBLIC_KEY: 'BNcRdreALRFXTkOOUHK1EtK2wtaz5Ry4YfYCA_0QTpQtUbVlUls0VJXg7A8u-Ts1XbjhazAkj7I99e8QcYP7DkM'
		}
	},
	use: {
		baseURL: 'http://localhost:4173',
		timezoneId: 'America/Los_Angeles',
		launchOptions: executablePath ? { executablePath } : {}
	},
	projects: [
		{ name: 'mobile', use: { ...devices['Pixel 7'], timezoneId: 'America/Los_Angeles', launchOptions: executablePath ? { executablePath } : {} } }
	]
});
