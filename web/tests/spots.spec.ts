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
	await expect(page.getByRole('heading', { name: 'Kubota Garden hill', exact: true })).toBeVisible();
	await expect(page.getByText('No weather reports near here yet.', { exact: false })).toBeVisible();
	await page.getByLabel('Ground elevation (ft above sea level)').fill('260');
	await page.getByLabel(/Search radius/).fill('15');
	await page.getByRole('button', { name: 'Save changes' }).click();
	await expect(page.getByText('Within 15 nm')).toBeVisible();
	expect(backend.writes.find((w) => w.method === 'PATCH')).toMatchObject({ method: 'PATCH', body: { elevation_ft: 260, search_radius_nm: 15 } });

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

test('spot page shows plain-language sky from nearby stations', async ({ page }) => {
	const backend = await mockBackend(page, {
		weather: [
			{ station: 'KBFI', station_name: 'Seattle/Boeing Fld, WA, US', distance_nm: 1.6, bearing_deg: 310,
			  station_elevation_ft: 20, observed_at: new Date().toISOString(), age_min: 12, flight_category: 'VFR',
			  is_auto: false, visibility_sm: 10, visibility_is_min: true, wx_string: null,
			  raw_text: 'KBFI 041853Z 17006KT 10SM FEW025 BKN060 12/08 A3001',
			  sky_summary: 'A few wisps at 2,500 ft above ground, then mostly cloudy with gaps at 6,000 ft above ground',
			  layers: [] },
			{ station: 'KRNT', station_name: 'Renton Muni, WA, US', distance_nm: 2.5, bearing_deg: 120,
			  station_elevation_ft: 30, observed_at: new Date().toISOString(), age_min: 125, flight_category: 'VFR',
			  is_auto: true, visibility_sm: 10, visibility_is_min: true, wx_string: '-RA',
			  raw_text: 'KRNT 041653Z AUTO 00000KT 10SM -RA CLR 11/07 A3002',
			  sky_summary: "No cloud below 12,000 ft (automated sensor; it can't see higher)", layers: [] }
		]
	});
	await signIn(page);
	await page.getByRole('link', { name: 'Add spot' }).click();
	await page.getByLabel('Name').fill('Kubota Garden hill');
	await page.getByPlaceholder('latitude, longitude').fill('47.5134, -122.2712');
	await page.getByRole('button', { name: 'Go' }).click();
	await expect(page.getByLabel('Ground elevation (ft above sea level)')).toHaveValue('200');
	await page.getByRole('button', { name: 'Save spot' }).click();
	await page.getByText('Kubota Garden hill').click();

	const sky = page.getByRole('region', { name: 'Sky near this spot' });
	await expect(sky.getByText('mostly cloudy with gaps at 6,000 ft above ground')).toBeVisible();
	await expect(sky.getByText('1.6 nm NW')).toBeVisible();
	await expect(sky.getByText('Reported 12 min ago')).toBeVisible();
	await expect(sky.getByText('Reported 2 h 5 min ago (old report)')).toBeVisible();
	await expect(sky.getByText("No cloud below 12,000 ft (automated sensor; it can't see higher)")).toBeVisible();
	await expect(sky.getByText('over 10 mi visibility').first()).toBeVisible();
	expect(backend.writes.find((w) => w.method === 'RPC nearby_weather')?.body).toBe(backend.spots[0].id);
	await page.screenshot({ path: 'test-results/spot-weather.png', fullPage: true });
});

test('spot page lists upcoming passes with where to look', async ({ page }) => {
	const soon = (min: number) => new Date(Date.now() + min * 60_000).toISOString();
	const backend = await mockBackend(page, {
		passes: [
			{ id: 1, basis: 'live_adsb', callsign: 'ASA123', icao24: 'a1b2c3', aircraft_type: null,
			  closest_approach_at: soon(0.3), closest_distance_nm: 0.4, altitude_ft: 10000, azimuth_deg: 12,
			  elevation_deg: 84, confidence: 0.92, computed_at: soon(0),
			  visibility_assessment: { rating: 'partial', high_cloud_caveat: false, metar_station: 'KBFI', obs_age_min: 12,
			    stations_used: ['KBFI', 'KRNT'], computed_at: soon(0),
			    explanation: 'Mostly cloudy at about 6,000 ft, so the aircraft will be above the clouds and visible only through gaps.' } },
			{ id: 2, basis: 'live_adsb', callsign: null, icao24: 'c0ffee', aircraft_type: null,
			  closest_approach_at: soon(6.2), closest_distance_nm: 4.95, altitude_ft: 35000, azimuth_deg: 90,
			  elevation_deg: 48.8, confidence: 0.62, computed_at: soon(0), visibility_assessment: null }
		]
	});
	await signIn(page);
	await page.getByRole('link', { name: 'Add spot' }).click();
	await page.getByLabel('Name').fill('Kubota Garden hill');
	await page.getByPlaceholder('latitude, longitude').fill('47.5134, -122.2712');
	await page.getByRole('button', { name: 'Go' }).click();
	await expect(page.getByLabel('Ground elevation (ft above sea level)')).toHaveValue('200');
	await page.getByRole('button', { name: 'Save spot' }).click();
	await page.getByText('Kubota Garden hill').click();

	const list = page.getByRole('region', { name: 'Coming overhead' });
	await expect(list.getByText('ASA123')).toBeVisible();
	await expect(list.getByText('Passing now')).toBeVisible();
	await expect(list.getByText('Straight overhead, 0.4 nm from you')).toBeVisible();
	await expect(list.getByText('Partly visible')).toBeVisible();
	await expect(list.getByText('visible only through gaps')).toBeVisible();
	await expect(list.getByText('Live tracking · High confidence · Weather from KBFI, 12 min old')).toBeVisible();
	await expect(list.getByText(/^C0FFEE, 35,000 ft, passes at /)).toBeVisible();
	await expect(list.getByText('in 6 min')).toBeVisible();
	await expect(list.getByText('Look E (90°), 49° above the horizon, 5.0 nm from you')).toBeVisible();
	await expect(list.getByText('Visibility unknown')).toBeVisible();
	await expect(list.getByText('Checking the weather for this pass…')).toBeVisible();
	await expect(list.getByText('Live tracking · Medium confidence')).toBeVisible();
	const q = backend.writes.find((w) => w.method === 'GET overflight_prediction')!.body as Record<string, string>;
	expect(q.spot_id).toBe(`eq.${backend.spots[0].id}`);
	expect(q.order).toBe('closest_approach_at.asc');
	expect(q.select).toContain('visibility_assessment(rating,explanation');
	await page.getByRole('region', { name: 'Coming overhead' }).screenshot({ path: 'test-results/passes.png' });
});
