import { expect, test } from '@playwright/test';
import { fakePushService, mockBackend } from './mock-supabase';

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
		min_elevation_deg: 20,
		time_zone: 'America/Los_Angeles', // from the browser (see playwright.config.ts)
		alerts_enabled: false,
		alerts_min_rating: 'clear',
		alerts_lead_min: 10
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
			    stations_used: ['KBFI', 'KRNT'], weather_basis: 'metar', computed_at: soon(0),
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

test('regular flights and usual-flight passes', async ({ page }) => {
	const tomorrowEvening = new Date(Date.now() + 26 * 3600_000).toISOString();
	await mockBackend(page, {
		regulars: [
			{ id: 1, callsign: 'ASA123', typical_local_time: '19:40:00', days_of_week: [1, 2, 3, 4, 5],
			  observation_count: 9, distinct_days: 8, time_spread_min: 4, typical_altitude_ft: 33000,
			  typical_azimuth_deg: 40, typical_elevation_deg: 70, last_seen_at: new Date().toISOString() }
		],
		passes: [
			{ id: 9, basis: 'recurring', callsign: 'ASA123', icao24: null, aircraft_type: null,
			  closest_approach_at: tomorrowEvening, closest_distance_nm: 1.5, altitude_ft: 33000, azimuth_deg: 40,
			  elevation_deg: 70, confidence: 0.7, computed_at: new Date().toISOString(), visibility_assessment: null }
		]
	});
	await signIn(page);
	await page.getByRole('link', { name: 'Add spot' }).click();
	await page.getByLabel('Name').fill('Kubota Garden hill');
	await page.getByPlaceholder('latitude, longitude').fill('47.5134, -122.2712');
	await page.getByRole('button', { name: 'Go' }).click();
	await expect(page.getByLabel('Time zone')).toHaveValue('America/Los_Angeles');
	await expect(page.getByLabel('Ground elevation (ft above sea level)')).toHaveValue('200');
	await page.getByRole('button', { name: 'Save spot' }).click();
	await page.getByText('Kubota Garden hill').click();

	const regs = page.getByRole('region', { name: 'Regulars over this spot' });
	await expect(regs.getByText('about 7:40 pm, Mon–Fri')).toBeVisible();
	await expect(regs.getByText('33,000 ft, look NE, 70° up')).toBeVisible();
	await expect(regs.getByText('Seen 9 times on 8 days, usually within 4 min of that time')).toBeVisible();

	const passes = page.getByRole('region', { name: 'Coming overhead' });
	await expect(passes.getByText(/^ASA123, 33,000 ft, passes (tomorrow|\w{3}) at /)).toBeVisible();
	await expect(passes.getByText('Usual flight · Medium confidence')).toBeVisible();
});

test('notifications: turn on, alert settings, remind me', async ({ page, context }) => {
	await context.grantPermissions(['notifications']);
	await fakePushService(page);
	const passAt = new Date(Date.now() + 3 * 3600_000).toISOString();
	const backend = await mockBackend(page, {
		passes: [
			{ id: 9, basis: 'recurring', callsign: 'ASA123', icao24: null, aircraft_type: null,
			  closest_approach_at: passAt, closest_distance_nm: 1.5, altitude_ft: 33000, azimuth_deg: 40,
			  elevation_deg: 70, confidence: 0.7, computed_at: new Date().toISOString(), visibility_assessment: null }
		]
	});
	await signIn(page);

	const card = page.getByRole('region', { name: 'Notifications on this device' });
	await card.getByRole('button', { name: 'Turn on notifications' }).click();
	await expect(card.getByRole('button', { name: 'Turn off on this device' })).toBeVisible();
	expect(backend.writes.find((w) => w.method === 'RPC save_push_subscription')?.body).toMatchObject({
		p_endpoint: 'https://push.example/test-device', p_p256dh: 'test-p256dh', p_auth: 'test-auth'
	});

	// Spot with alerts on: partly visible too, 15 minutes ahead.
	await page.getByRole('link', { name: 'Add spot' }).click();
	await page.getByLabel('Name').fill('Kubota Garden hill');
	await page.getByPlaceholder('latitude, longitude').fill('47.5134, -122.2712');
	await page.getByRole('button', { name: 'Go' }).click();
	await expect(page.getByLabel('Ground elevation (ft above sea level)')).toHaveValue('200');
	await page.getByLabel('Alert me before good passes').check();
	await page.getByLabel('Which passes').selectOption('partial');
	await page.getByLabel('Minutes ahead').fill('15');
	await page.getByRole('button', { name: 'Save spot' }).click();
	await expect(page.getByText('Alerts on: clear or partly visible, 15 min ahead')).toBeVisible();
	expect(backend.writes.find((w) => w.method === 'POST')?.body).toMatchObject({
		alerts_enabled: true, alerts_min_rating: 'partial', alerts_lead_min: 15
	});

	// Remind me on a usual-flight pass: 15 min before.
	await page.getByText('Kubota Garden hill').click();
	const passes = page.getByRole('region', { name: 'Coming overhead' });
	await passes.getByRole('button', { name: 'Remind me' }).click();
	await expect(passes.getByRole('button', { name: 'Reminder set · cancel' })).toBeVisible();
	const reminder = backend.writes.find((w) => w.method === 'POST alert')!.body as Record<string, unknown>;
	expect(reminder).toMatchObject({ prediction_id: 9, manual: true, spot_id: backend.spots[0].id });
	expect(Math.abs(new Date(reminder.notify_at as string).getTime() - (new Date(passAt).getTime() - 15 * 60_000))).toBeLessThan(2000);
	await passes.getByRole('button', { name: 'Reminder set · cancel' }).click();
	await expect(passes.getByRole('button', { name: 'Remind me' })).toBeVisible();

	// Service worker is actually registered by the app.
	expect(await page.evaluate(async () => (await navigator.serviceWorker.getRegistration())?.active?.scriptURL)).toMatch(/service-worker\.js$/);
});

test('remind me is disabled until notifications are on', async ({ page }) => {
	await mockBackend(page, {
		passes: [
			{ id: 9, basis: 'recurring', callsign: 'ASA123', icao24: null, aircraft_type: null,
			  closest_approach_at: new Date(Date.now() + 3 * 3600_000).toISOString(), closest_distance_nm: 1.5,
			  altitude_ft: 33000, azimuth_deg: 40, elevation_deg: 70, confidence: 0.7,
			  computed_at: new Date().toISOString(), visibility_assessment: null }
		]
	});
	await signIn(page);
	await page.getByRole('link', { name: 'Add spot' }).click();
	await page.getByLabel('Name').fill('X');
	await page.getByPlaceholder('latitude, longitude').fill('47.5134, -122.2712');
	await page.getByRole('button', { name: 'Go' }).click();
	await expect(page.getByLabel('Ground elevation (ft above sea level)')).toHaveValue('200');
	await page.getByRole('button', { name: 'Save spot' }).click();
	await page.getByText('X', { exact: true }).click();
	const passes = page.getByRole('region', { name: 'Coming overhead' });
	await expect(passes.getByRole('button', { name: 'Remind me' })).toBeDisabled();
	await expect(passes.getByText('Turn on notifications on the home page to use reminders.')).toBeVisible();
});

test('service worker shows a delivered push as a notification', async ({ page, context }) => {
	await context.grantPermissions(['notifications']);
	await mockBackend(page);
	await signIn(page);
	await page.evaluate(() => navigator.serviceWorker.ready);

	// Deliver a push straight to the registered worker via Chrome DevTools Protocol.
	const cdp = await context.newCDPSession(page);
	const registrationId = new Promise<string>((resolve) => {
		cdp.on('ServiceWorker.workerRegistrationUpdated', (e) => {
			const r = e.registrations.find((x) => x.scopeURL.startsWith('http://localhost:4173'));
			if (r) resolve(r.registrationId);
		});
	});
	await cdp.send('ServiceWorker.enable');
	await cdp.send('ServiceWorker.deliverPushMessage', {
		origin: 'http://localhost:4173',
		registrationId: await registrationId,
		data: JSON.stringify({ title: 'ASA123 overhead in 6 min', body: 'Clear view · 33,000 ft', tag: 'pass-42', url: '/spots/abc' })
	});

	await expect
		.poll(async () =>
			page.evaluate(async () => {
				const reg = await navigator.serviceWorker.ready;
				return (await reg.getNotifications()).map((n) => `${n.title} | ${n.body} | ${n.tag} | ${n.data?.url}`);
			})
		)
		.toEqual(['ASA123 overhead in 6 min | Clear view · 33,000 ft | pass-42 | /spots/abc']);
});
