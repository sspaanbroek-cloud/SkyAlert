/// <reference no-default-lib="true"/>
/// <reference lib="esnext" />
/// <reference lib="webworker" />
// Shows SkyAlert push notifications and opens the spot when one is tapped.
// SvelteKit registers this file automatically.

const sw = self as unknown as ServiceWorkerGlobalScope;

sw.addEventListener('install', () => sw.skipWaiting());
sw.addEventListener('activate', (event) => event.waitUntil(sw.clients.claim()));

sw.addEventListener('push', (event) => {
	let data: { title?: string; body?: string; tag?: string; url?: string } = {};
	try {
		data = event.data?.json() ?? {};
	} catch {
		data = { body: event.data?.text() };
	}
	event.waitUntil(
		sw.registration.showNotification(data.title ?? 'SkyAlert', {
			body: data.body,
			tag: data.tag,
			icon: '/icon-192.png',
			badge: '/icon-192.png',
			data: { url: data.url ?? '/' }
		})
	);
});

sw.addEventListener('notificationclick', (event) => {
	event.notification.close();
	const url = new URL((event.notification.data?.url as string) ?? '/', sw.location.origin).href;
	event.waitUntil(
		(async () => {
			const windows = await sw.clients.matchAll({ type: 'window', includeUncontrolled: true });
			const open = windows.find((w) => w.url.startsWith(sw.location.origin));
			if (open) {
				await open.focus();
				await open.navigate(url);
			} else {
				await sw.clients.openWindow(url);
			}
		})()
	);
});
