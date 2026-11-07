import type { Page, Route } from '@playwright/test';

// In-browser stand-in for Supabase Auth + PostgREST (spot table only), plus
// the map tile and elevation services. Records what the app sends.

const SUPABASE = 'http://supabase.test';
const USER_ID = '11111111-1111-1111-1111-111111111111';

const b64url = (o: object) => Buffer.from(JSON.stringify(o)).toString('base64url');
function fakeJwt() {
	const now = Math.floor(Date.now() / 1000);
	return `${b64url({ alg: 'HS256', typ: 'JWT' })}.${b64url({ sub: USER_ID, role: 'authenticated', exp: now + 3600, iat: now })}.sig`;
}

const PNG_1PX = Buffer.from(
	'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII=',
	'base64'
);

export interface SpotRow {
	id: string;
	user_id: string;
	name: string;
	geog: string;
	lat: number;
	lon: number;
	elevation_ft: number;
	search_radius_nm: number;
	min_elevation_deg: number;
	time_zone: string;
	updated_at: string;
}

export async function mockBackend(page: Page, opts: { elevationM?: number | null; weather?: unknown[]; passes?: unknown[]; regulars?: unknown[]; forecast?: unknown[] } = {}) {
	const spots: SpotRow[] = [];
	const writes: { method: string; body: unknown }[] = [];
	const alerts: { prediction_id: number; manual: boolean; notify_at: string; spot_id: string }[] = [];
	let nextId = 1;

	const user: Record<string, unknown> = { id: USER_ID, email: 'pilot@example.com', aud: 'authenticated', role: 'authenticated', phone: '' };
	let prefs: Record<string, unknown> | null = null;
	const session = () => ({
		access_token: fakeJwt(),
		token_type: 'bearer',
		expires_in: 3600,
		expires_at: Math.floor(Date.now() / 1000) + 3600,
		refresh_token: 'refresh',
		user
	});

	const json = (route: Route, status: number, body: unknown) =>
		route.fulfill({ status, contentType: 'application/json', body: JSON.stringify(body) });

	await page.route('https://tile.openstreetmap.org/**', (r) => r.fulfill({ contentType: 'image/png', body: PNG_1PX }));
	await page.route('https://api.open-meteo.com/**', (r) =>
		opts.elevationM === null ? r.fulfill({ status: 503 }) : json(r, 200, { elevation: [opts.elevationM ?? 61] })
	);

	await page.route(`${SUPABASE}/auth/v1/**`, async (route) => {
		const url = new URL(route.request().url());
		if (url.pathname.endsWith('/token')) {
			const body = route.request().postDataJSON() as { password?: string };
			if (body.password !== 'correct-horse')
				return json(route, 400, { code: 400, error_code: 'invalid_credentials', msg: 'Invalid login credentials' });
			return json(route, 200, session());
		}
		if (url.pathname.endsWith('/logout')) return route.fulfill({ status: 204 });
		if (url.pathname.endsWith('/otp')) {
			writes.push({ method: 'AUTH otp', body: route.request().postDataJSON() });
			return json(route, 200, {});
		}
		if (url.pathname.endsWith('/verify')) {
			const body = route.request().postDataJSON() as { phone: string; token: string; type: string };
			writes.push({ method: 'AUTH verify', body });
			if (body.token !== '123456') return json(route, 403, { code: 403, error_code: 'otp_expired', msg: 'Token has expired or is invalid' });
			Object.assign(user, { phone: body.phone.replace(/^\+/, ''), phone_confirmed_at: new Date().toISOString() });
			if (body.type === 'sms') user.email = '';
			return json(route, 200, session());
		}
		if (url.pathname.endsWith('/user') && route.request().method() === 'PUT') {
			writes.push({ method: 'AUTH update user', body: route.request().postDataJSON() });
			return json(route, 200, user);
		}
		if (url.pathname.endsWith('/user')) return json(route, 200, user);
		return json(route, 404, { msg: 'not mocked' });
	});

	await page.route(`${SUPABASE}/rest/v1/rpc/nearby_weather`, async (route) => {
		const { p_spot_id } = route.request().postDataJSON() as { p_spot_id: string };
		writes.push({ method: 'RPC nearby_weather', body: p_spot_id });
		return json(route, 200, opts.weather ?? []);
	});

	await page.route(`${SUPABASE}/rest/v1/rpc/nearby_forecast`, (route) => json(route, 200, opts.forecast ?? []));

	await page.route(`${SUPABASE}/rest/v1/rpc/*_push_subscription`, async (route) => {
		const name = new URL(route.request().url()).pathname.split('/').pop()!;
		writes.push({ method: `RPC ${name}`, body: route.request().postDataJSON() });
		return route.fulfill({ status: 204 });
	});

	await page.route(`${SUPABASE}/rest/v1/alert**`, async (route) => {
		const req = route.request();
		const url = new URL(req.url());
		if (req.method() === 'GET') return json(route, 200, alerts);
		if (req.method() === 'POST') {
			const body = req.postDataJSON();
			writes.push({ method: 'POST alert', body });
			alerts.push(body);
			return route.fulfill({ status: 201 });
		}
		if (req.method() === 'DELETE') {
			const pid = Number(url.searchParams.get('prediction_id')?.replace('eq.', ''));
			writes.push({ method: 'DELETE alert', body: pid });
			alerts.splice(0, alerts.length, ...alerts.filter((a) => a.prediction_id !== pid));
			return route.fulfill({ status: 204 });
		}
		return json(route, 405, {});
	});

	await page.route(`${SUPABASE}/rest/v1/notification_pref**`, async (route) => {
		const req = route.request();
		if (req.method() === 'POST') {
			const body = req.postDataJSON();
			writes.push({ method: 'UPSERT notification_pref', body });
			prefs = { push_enabled: true, sms_opted_out_at: null, ...(prefs ?? {}), ...body };
			return route.fulfill({ status: 201 });
		}
		const wantsObject = (req.headers()['accept'] ?? '').includes('vnd.pgrst.object');
		if (!prefs) return wantsObject ? json(route, 406, { code: 'PGRST116', message: 'no rows' }) : json(route, 200, []);
		return json(route, 200, wantsObject ? prefs : [prefs]);
	});

	await page.route(`${SUPABASE}/rest/v1/recurring_flight**`, (route) => json(route, 200, opts.regulars ?? []));

	await page.route(`${SUPABASE}/rest/v1/overflight_prediction**`, async (route) => {
		const url = new URL(route.request().url());
		writes.push({ method: 'GET overflight_prediction', body: Object.fromEntries(url.searchParams) });
		return json(route, 200, opts.passes ?? []);
	});

	await page.route(`${SUPABASE}/rest/v1/spot**`, async (route) => {
		const req = route.request();
		const url = new URL(req.url());
		const idEq = url.searchParams.get('id')?.replace(/^eq\./, '');
		const wantsObject = (req.headers()['accept'] ?? '').includes('vnd.pgrst.object');
		const pick = (rows: SpotRow[]) => (idEq ? rows.filter((s) => s.id === idEq) : rows);
		const respond = (rows: SpotRow[], status = 200) => {
			if (!wantsObject) return json(route, status, rows);
			if (rows.length !== 1)
				return json(route, 406, { code: 'PGRST116', message: 'JSON object requested, multiple (or no) rows returned' });
			return json(route, status, rows[0]);
		};
		const fromGeog = (geog: string) => {
			const m = geog.match(/^SRID=4326;POINT\((\S+) (\S+)\)$/);
			if (!m) throw new Error(`bad geog ${geog}`);
			return { lon: Number(m[1]), lat: Number(m[2]) };
		};

		switch (req.method()) {
			case 'GET':
				return respond(pick(spots).sort((a, b) => a.name.localeCompare(b.name)));
			case 'POST': {
				const body = req.postDataJSON();
				writes.push({ method: 'POST', body });
				const row: SpotRow = {
					id: `00000000-0000-0000-0000-${String(nextId++).padStart(12, '0')}`,
					user_id: USER_ID,
					...body,
					...fromGeog(body.geog),
					updated_at: new Date().toISOString()
				};
				spots.push(row);
				return respond([row], 201);
			}
			case 'PATCH': {
				const body = req.postDataJSON();
				writes.push({ method: 'PATCH', body });
				const rows = pick(spots);
				for (const r of rows) Object.assign(r, body, body.geog ? fromGeog(body.geog) : {});
				return respond(rows);
			}
			case 'DELETE': {
				writes.push({ method: 'DELETE', body: idEq });
				for (const r of pick(spots)) spots.splice(spots.indexOf(r), 1);
				return route.fulfill({ status: 204 });
			}
		}
		return json(route, 405, {});
	});

	return { spots, writes, alerts };
}

/**
 * Headless Chromium can't reach a real push service, so replace only the
 * PushManager subscribe/getSubscription calls with a fake subscription.
 * Everything else (service worker registration, permission) is real.
 */
export async function fakePushService(page: Page) {
	await page.addInitScript(() => {
		let current: unknown = null;
		const fake = {
			endpoint: 'https://push.example/test-device',
			toJSON: () => ({ endpoint: 'https://push.example/test-device', keys: { p256dh: 'test-p256dh', auth: 'test-auth' } }),
			unsubscribe: async () => {
				current = null;
				return true;
			}
		};
		if ('PushManager' in window) {
			PushManager.prototype.subscribe = async function () {
				current = fake;
				return fake as unknown as PushSubscription;
			};
			PushManager.prototype.getSubscription = async function () {
				return current as PushSubscription | null;
			};
		}
	});
}
