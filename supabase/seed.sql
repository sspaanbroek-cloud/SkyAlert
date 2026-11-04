-- Dev seed (runs on `supabase db reset`). Production airports come from METAR ingest.
insert into public.aircraft_type (icao_type, manufacturer, model, typical_cruise_ft) values
  ('A320', 'Airbus',    'A320',          37000),
  ('A20N', 'Airbus',    'A320neo',       37000),
  ('A21N', 'Airbus',    'A321neo',       37000),
  ('A333', 'Airbus',    'A330-300',      39000),
  ('A359', 'Airbus',    'A350-900',      41000),
  ('A388', 'Airbus',    'A380-800',      39000),
  ('B738', 'Boeing',    '737-800',       37000),
  ('B38M', 'Boeing',    '737 MAX 8',     37000),
  ('B744', 'Boeing',    '747-400',       35000),
  ('B748', 'Boeing',    '747-8',         37000),
  ('B77W', 'Boeing',    '777-300ER',     37000),
  ('B789', 'Boeing',    '787-9',         41000),
  ('E75L', 'Embraer',   'E175',          35000),
  ('CRJ9', 'Bombardier','CRJ-900',       35000),
  ('DH8D', 'De Havilland Canada', 'Dash 8-400', 25000),
  ('C172', 'Cessna',    '172 Skyhawk',    6000)
on conflict (icao_type) do nothing;

insert into public.airport (icao, name, geog, elevation_ft) values
  ('KSEA', 'Seattle-Tacoma Intl', 'SRID=4326;POINT(-122.3088 47.4502)', 433),
  ('KBFI', 'Boeing Field/King County Intl', 'SRID=4326;POINT(-122.3019 47.5300)', 21)
on conflict (icao) do nothing;
