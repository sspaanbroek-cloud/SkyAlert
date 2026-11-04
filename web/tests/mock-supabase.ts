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
	updated_at: string;
}

export async function mockBackend(page: Page, opts: { elevationM?: number | null } = {}) {
	const spots: SpotRow[] = [];
	const writes: { method: string; body: unknown }[] = [];
	let nextId = 1;

	const user = { id: USER_ID, email: 'pilot@example.com', aud: 'authenticated', role: 'authenticated' };
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
		if (url.pathname.endsWith('/user')) return json(route, 200, user);
		return json(route, 404, { msg: 'not mocked' });
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

	return { spots, writes };
}
