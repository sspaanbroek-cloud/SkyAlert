<script lang="ts">
	import 'leaflet/dist/leaflet.css';
	import type { LatLon } from '#lib/geo.ts';
	import { nmToM } from '#lib/geo.ts';
	import type * as Leaflet from 'leaflet';

	interface Props {
		/** Pin position; null until the user places it. */
		value: LatLon | null;
		radiusNm: number;
		onchange: (p: LatLon) => void;
	}
	let { value, radiusNm, onchange }: Props = $props();

	let el: HTMLDivElement;
	let L: typeof Leaflet | undefined = $state();
	let map: Leaflet.Map | undefined = $state();
	let marker: Leaflet.Marker | undefined;
	let circle: Leaflet.Circle | undefined;

	const tileUrl = import.meta.env.VITE_MAP_TILE_URL ?? 'https://tile.openstreetmap.org/{z}/{x}/{y}.png';
	const attribution =
		import.meta.env.VITE_MAP_ATTRIBUTION ??
		'&copy; <a href="https://www.openstreetmap.org/copyright">OpenStreetMap</a> contributors';

	// Create the map once.
	$effect(() => {
		let cancelled = false;
		let created: Leaflet.Map | undefined;
		import('leaflet').then((mod) => {
			if (cancelled) return;
			L = mod.default ?? mod;
			const start = value ?? { lat: 39.5, lon: -98.35 }; // continental US if nothing chosen
			created = L.map(el, { zoomControl: true }).setView([start.lat, start.lon], value ? 11 : 4);
			L.tileLayer(tileUrl, { maxZoom: 19, attribution }).addTo(created);
			created.on('click', (e: Leaflet.LeafletMouseEvent) =>
				onchange({ lat: e.latlng.lat, lon: e.latlng.lng })
			);
			map = created;
			// Content loading above the map (e.g. the weather card) moves/resizes it;
			// Leaflet must re-measure or vector layers render clipped.
			resizeObserver = new ResizeObserver(() => created?.invalidateSize());
			resizeObserver.observe(el);
		});
		let resizeObserver: ResizeObserver | undefined;
		return () => {
			cancelled = true;
			resizeObserver?.disconnect();
			created?.remove();
		};
	});

	// Keep pin + radius circle in sync with props.
	$effect(() => {
		if (!L || !map || !value) return;
		const ll = L.latLng(value.lat, value.lon);
		const radiusM = nmToM(radiusNm > 0 ? radiusNm : 0);
		if (!marker) {
			marker = L.marker(ll, {
				draggable: true,
				keyboard: true,
				title: 'Shooting spot (drag to move)',
				icon: L.divIcon({ className: 'spot-pin', iconSize: [22, 22], iconAnchor: [11, 11] })
			}).addTo(map);
			marker.on('dragend', () => {
				const p = marker!.getLatLng();
				onchange({ lat: p.lat, lon: p.lng });
			});
			circle = L.circle(ll, { radius: radiusM, className: 'spot-radius', interactive: false }).addTo(map);
			map.fitBounds(circle.getBounds(), { padding: [16, 16] });
		} else {
			marker.setLatLng(ll);
			circle!.setLatLng(ll).setRadius(radiusM);
		}
	});

	/** Re-centre on the pin + radius (e.g. after "use my location"). */
	export function focus() {
		if (map && circle) map.fitBounds(circle.getBounds(), { padding: [16, 16] });
	}
</script>

<div class="wrap">
	<div class="map" class:empty={!value} bind:this={el} role="application" aria-label="Map. Tap to place your shooting spot."></div>
	{#if !value}<div class="tap-hint" aria-hidden="true">Tap the map to place your spot</div>{/if}
</div>

<style>
	.wrap {
		position: relative;
	}
	.map.empty {
		cursor: crosshair;
	}
	.tap-hint {
		position: absolute;
		left: 50%;
		bottom: 28px;
		transform: translateX(-50%);
		z-index: 500;
		pointer-events: none;
		padding: 6px 12px;
		border-radius: 999px;
		background: var(--surface);
		color: var(--text);
		font-size: 0.875rem;
		font-weight: 600;
		box-shadow: 0 1px 4px rgb(0 0 0 / 0.25);
		white-space: nowrap;
	}
	.map {
		height: min(55vh, 420px);
		border-radius: var(--radius);
		border: 1px solid var(--border);
		z-index: 0;
	}
	:global(.spot-pin) {
		background: var(--accent);
		border: 3px solid #fff;
		border-radius: 50%;
		box-shadow: 0 1px 4px rgb(0 0 0 / 0.5);
	}
	:global(.spot-radius) {
		stroke: var(--accent);
		stroke-width: 2;
		fill: var(--accent);
		fill-opacity: 0.08;
	}
</style>
