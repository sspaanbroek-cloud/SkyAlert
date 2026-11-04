import { supabase } from './supabase';

export type PushState = 'unsupported' | 'ios-home-screen' | 'denied' | 'off' | 'on' | 'no-key';

const vapidKey = () => import.meta.env.VITE_VAPID_PUBLIC_KEY as string | undefined;

function isIos(): boolean {
	return /iPad|iPhone|iPod/.test(navigator.userAgent) || (navigator.platform === 'MacIntel' && navigator.maxTouchPoints > 1);
}

function isStandalone(): boolean {
	return (
		window.matchMedia?.('(display-mode: standalone)').matches ||
		(navigator as unknown as { standalone?: boolean }).standalone === true
	);
}

export async function pushState(): Promise<PushState> {
	if (!vapidKey()) return 'no-key';
	const supported = 'serviceWorker' in navigator && 'PushManager' in window && 'Notification' in window;
	if (!supported) return isIos() && !isStandalone() ? 'ios-home-screen' : 'unsupported';
	if (Notification.permission === 'denied') return 'denied';
	const reg = await navigator.serviceWorker.ready;
	const sub = await reg.pushManager.getSubscription();
	return sub && Notification.permission === 'granted' ? 'on' : 'off';
}

/** VAPID public key (base64url) -> bytes for pushManager.subscribe(). */
export function urlBase64ToUint8Array(base64: string): Uint8Array {
	const padded = (base64 + '='.repeat((4 - (base64.length % 4)) % 4)).replace(/-/g, '+').replace(/_/g, '/');
	const raw = atob(padded);
	return Uint8Array.from(raw, (c) => c.charCodeAt(0));
}

export async function enablePush(): Promise<PushState> {
	const key = vapidKey();
	if (!key) return 'no-key';
	const permission = await Notification.requestPermission();
	if (permission !== 'granted') return permission === 'denied' ? 'denied' : 'off';
	const reg = await navigator.serviceWorker.ready;
	const sub =
		(await reg.pushManager.getSubscription()) ??
		(await reg.pushManager.subscribe({ userVisibleOnly: true, applicationServerKey: urlBase64ToUint8Array(key) as BufferSource }));
	const json = sub.toJSON() as { endpoint?: string; keys?: { p256dh?: string; auth?: string } };
	const { error } = await supabase.rpc('save_push_subscription', {
		p_endpoint: json.endpoint ?? sub.endpoint,
		p_p256dh: json.keys?.p256dh,
		p_auth: json.keys?.auth,
		p_user_agent: navigator.userAgent
	});
	if (error) throw error;
	return 'on';
}

export async function disablePush(): Promise<PushState> {
	const reg = await navigator.serviceWorker.ready;
	const sub = await reg.pushManager.getSubscription();
	if (sub) {
		await supabase.rpc('remove_push_subscription', { p_endpoint: sub.endpoint });
		await sub.unsubscribe();
	}
	return 'off';
}

export const notificationsGranted = () => typeof Notification !== 'undefined' && Notification.permission === 'granted';
