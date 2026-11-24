-- Firstbox app: fetch a client's name and address from their GSTIN (Invoices › Billed To › Fetch details).
-- Uses the AppyFlow GST verification service (https://appyflow.in/verify-gst/). The service key is stored in a
-- table nobody can read through the app; only these functions use it. Safe to run again.
create extension if not exists http with schema extensions;

create table if not exists public.app_secrets (
  name text primary key,
  value text not null,
  updated_at timestamptz not null default now()
);
alter table public.app_secrets enable row level security;
revoke all on public.app_secrets from anon, authenticated;

-- Owner saves (or clears) the key from ⚙ Billing details.
create or replace function public.set_gst_api_key(p_key text)
returns void
language plpgsql security definer set search_path = public as $$
declare v_key text := trim(coalesce(p_key, ''));
begin
  if public.my_role() not in ('owner','admin') then raise exception 'Only the owner or an admin can set the GST lookup key'; end if;
  if v_key = '' then delete from public.app_secrets where name = 'appyflow'; return; end if;
  if v_key !~ '^[A-Za-z0-9._-]{6,200}$' then raise exception 'That key does not look right. Copy the key secret again from AppyFlow.'; end if;
  insert into public.app_secrets (name, value) values ('appyflow', v_key)
    on conflict (name) do update set value = excluded.value, updated_at = now();
end $$;

create or replace function public.gst_key_set()
returns boolean
language sql stable security definer set search_path = public as $$
  select public.my_role() in ('owner','admin','jobcards') and exists (select 1 from public.app_secrets where name = 'appyflow');
$$;

-- Owner, admin and accounts team logins: returns AppyFlow's taxpayerInfo (lgnm, tradeNam, sts, pradr.addr …).
create or replace function public.gst_lookup(p_gstin text)
returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_g   text := upper(trim(coalesce(p_gstin, '')));
  v_key text;
  v_res extensions.http_response;
  v_j   jsonb;
begin
  if public.my_role() not in ('owner','admin','jobcards') then raise exception 'Not allowed'; end if;
  if v_g !~ '^[0-9]{2}[A-Z]{5}[0-9]{4}[A-Z][0-9A-Z]Z[0-9A-Z]$' then raise exception 'That is not a valid GSTIN'; end if;
  select value into v_key from public.app_secrets where name = 'appyflow';
  if v_key is null then raise exception 'GST lookup is not set up yet (⚙ Billing details)'; end if;
  v_res := extensions.http_get('https://appyflow.in/api/verifyGST?gstNo=' || v_g || '&key_secret=' || v_key);
  if v_res.status <> 200 then raise exception 'The GST lookup service did not answer (status %)', v_res.status; end if;
  begin v_j := v_res.content::jsonb; exception when others then raise exception 'The GST lookup service sent an unexpected answer'; end;
  if coalesce((v_j->>'error')::boolean, false) then raise exception '%', coalesce(v_j->>'message', 'GST lookup failed'); end if;
  if v_j->'taxpayerInfo' is null then raise exception 'No details found for this GSTIN'; end if;
  return v_j->'taxpayerInfo';
end $$;

revoke all on function public.set_gst_api_key(text) from public, anon;
revoke all on function public.gst_key_set() from public, anon;
revoke all on function public.gst_lookup(text) from public, anon;
grant execute on function public.set_gst_api_key(text) to authenticated;
grant execute on function public.gst_key_set() to authenticated;
grant execute on function public.gst_lookup(text) to authenticated;

select 'GST lookup ready' as result;
