import assert from 'node:assert/strict';
import { type FlightPlanInput, validatePlan } from './flightplan.ts';

const ok: FlightPlanInput = {
	source: 'aeroapi', source_ref: 'ASA123-1793800000-airline-0123', callsign: 'ASA123', origin: 'KPDX',
	destination: 'KPAE', aircraft_type: 'B738', filed_cruise_ft: 35000, filed_speed_kt: 450,
	filed_etd: '2026-11-04T20:00:00Z', route_string: 'BTG J1 SEA'
};

Deno.test('validatePlan', () => {
	assert.equal(validatePlan(ok), null);
	assert.equal(validatePlan({ ...ok, callsign: '' }), 'missing or invalid callsign');
	assert.equal(validatePlan({ ...ok, filed_etd: 'soon' }), 'invalid filed_etd');
	assert.equal(validatePlan({ ...ok, filed_speed_kt: 900 }), 'filed_speed_kt out of range');
});
