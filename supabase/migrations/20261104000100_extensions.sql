-- Extensions. Supabase convention: install into the `extensions` schema,
-- which is on the API search_path (see config.toml: extra_search_path).
create schema if not exists extensions;

create extension if not exists postgis with schema extensions;
create extension if not exists pgcrypto with schema extensions;  -- gen_random_uuid()
