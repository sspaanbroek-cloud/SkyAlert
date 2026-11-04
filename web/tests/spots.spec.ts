import { expect, test } from '@playwright/test';
import { mockBackend } from './mock-supabase';

async function signIn(page: import('@playwright/test').Page) {
	await page.goto('/');
	await expect(page).toHaveURL(/\/login$/);
	await page.getByLabel('Email').fill('pilot@example.com');
	await page.getByLabel('Password').fill('correct-horse');
	await page.getByRole('button', { name: 'Sign in', exact: true }).click();
	await expect(page.getByRole('heading', { name: 'Your shooting spots' })).toBeVisible();
}

test('wrong password shows an error', async ({ page }) => {
	await mockBackend(page);
	await page.goto('/login');
	await page.getByLabel('Email').fill('pilot@example.com');
	await page.getByLabel('Password').fill('nope-nope');
	await page.getByRole('button', { name: 'Sign in', exact: true }).click();
	await expect(page.getByRole('alert')).toHaveText('Invalid login credentials');
});

test('create, edit and delete a spot', async ({ page }) => {
	const backend = await mockBackend(page, { elevationM: 61 });
	await signIn(page);
	await expect(page.getByText('No spots yet.')).toBeVisible();

	// Create: type coordinates, elevation is looked up (61 m -> 200 ft)
	await page.getByRole('link', { name: 'Add spot' }).click();
	await page.getByLabel('Name').fill('Kubota Garden hill');
	await page.getByPlaceholder('latitude, longitude').fill('47.5134, -122.2712');
	await page.getByRole('button', { name: 'Go' }).click();
	await expect(page.getByTestId('point')).toHaveText('47.5134° N, 122.2712° W');
	await expect(page.getByLabel('Ground elevation (ft above sea level)')).toHaveValue('200');
	await expect(page.locator('.spot-pin')).toBeVisible();
	await expect(page.getByText('your 10 nm radius is the tighter limit')).toBeVisible();
	await page.screenshot({ path: 'test-results/new-spot.png', fullPage: true });
	await page.getByRole('button', { name: 'Save spot' }).click();

	await expect(page.getByRole('heading', { name: 'Your shooting spots' })).toBeVisible();
	await expect(page.getByText('Kubota Garden hill')).toBeVisible();
	await expect(page.getByText('Within 10 nm, at least 20° above the horizon')).toBeVisible();
	expect(backend.writes[0].body).toEqual({
		name: 'Kubota Garden hill',
		geog: 'SRID=4326;POINT(-122.2712 47.5134)',
		elevation_ft: 200,
		search_radius_nm: 10,
		min_elevation_deg: 20
	});
	await page.screenshot({ path: 'test-results/list.png', fullPage: true });

	// Edit: manual elevation sticks, radius changes
	await page.getByText('Kubota Garden hill').click();
	await expect(page.getByRole('heading', { name: 'Edit Kubota Garden hill' })).toBeVisible();
	await page.getByLabel('Ground elevation (ft above sea level)').fill('260');
	await page.getByLabel(/Search radius/).fill('15');
	await page.getByRole('button', { name: 'Save changes' }).click();
	await expect(page.getByText('Within 15 nm')).toBeVisible();
	expect(backend.writes[1]).toMatchObject({ method: 'PATCH', body: { elevation_ft: 260, search_radius_nm: 15 } });

	// Delete
	await page.getByText('Kubota Garden hill').click();
	page.once('dialog', (d) => d.accept());
	await page.getByRole('button', { name: 'Delete spot' }).click();
	await expect(page.getByText('No spots yet.')).toBeVisible();
	expect(backend.spots).toHaveLength(0);
});

test('tapping the map places the pin; failed elevation lookup asks for input', async ({ page }) => {
	await mockBackend(page, { elevationM: null });
	await signIn(page);
	await page.getByRole('link', { name: 'Add spot' }).click();
	const map = page.getByRole('application');
	await expect(map.locator('.leaflet-tile-loaded').first()).toBeAttached();
	await map.click();
	await expect(page.getByTestId('point')).toBeVisible();
	await expect(page.getByText("Couldn't look up elevation. Please type it in.")).toBeVisible();
	await page.getByLabel('Name').fill('Somewhere');
	await page.getByRole('button', { name: 'Save spot' }).click();
	await expect(page.getByRole('alert')).toHaveText('Enter the ground elevation of your spot in feet.');
});

test('use my location', async ({ page, context }) => {
	await context.grantPermissions(['geolocation']);
	await context.setGeolocation({ latitude: 51.4706, longitude: -0.4619 });
	await mockBackend(page);
	await signIn(page);
	await page.getByRole('link', { name: 'Add spot' }).click();
	await page.getByRole('button', { name: 'Use my location' }).click();
	await expect(page.getByTestId('point')).toHaveText('51.4706° N, 0.4619° W');
});
