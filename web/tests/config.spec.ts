import { expect, test } from '@playwright/test';

// A separate build without the Supabase settings must explain itself, not show a blank page.
test.skip(!process.env.SKYALERT_UNCONFIGURED_URL, 'run by the config check in the README');

test('a build without its settings says what is missing', async ({ page }) => {
	await page.goto(process.env.SKYALERT_UNCONFIGURED_URL!);
	await expect(page.getByRole('alert')).toContainText("SkyAlert isn't set up yet");
	await expect(page.getByRole('alert')).toContainText('VITE_SUPABASE_URL and VITE_SUPABASE_ANON_KEY');
});
