-- Firstbox app: make and cancel e-way bills straight from a tax invoice, through the GSP gstinapi.in
-- (https://www.gstinapi.in/e-way-bill-api). The gstinapi.in API key and the e-way bill API username/password are
-- kept in app_secrets, a table nobody can read through the app; only these functions use them.
-- Needs supabase/gst-lookup.sql first (it makes app_secrets and turns on the http extension). Safe to run again.
create extension if not exists http with schema extensions;

create table if not exists public.app_secrets (
  name text primary key,
  value text not null,
  updated_at timestamptz not null default now()
);
alter table public.app_secrets enable row level security;
revoke all on public.app_secrets from anon, authenticated;

-- Owner/admin save the details from ⚙ Billing details. null = keep what is saved, '' = remove it.
create or replace function public.set_ewb_api(p_key text, p_user text, p_pass text, p_test boolean)
returns void
language plpgsql security definer set search_path = public as $$
declare v_key text := trim(p_key); v_user text := trim(p_user);
begin
  if public.my_role() not in ('owner','admin') then raise exception 'Only the owner or an admin can set up the e-way bill connection'; end if;
  if v_key is not null then
    if v_key = '' then delete from public.app_secrets where name = 'gstinapi_key';
    elsif v_key !~ '^[A-Za-z0-9._-]{8,200}$' then raise exception 'That API key does not look right. Copy it again from the gstinapi.in dashboard.';
    else insert into public.app_secrets (name, value) values ('gstinapi_key', v_key) on conflict (name) do update set value = excluded.value, updated_at = now();
    end if;
  end if;
  if v_user is not null then
    if v_user = '' then delete from public.app_secrets where name = 'ewb_user';
    elsif length(v_user) > 100 then raise exception 'That username is too long';
    else insert into public.app_secrets (name, value) values ('ewb_user', v_user) on conflict (name) do update set value = excluded.value, updated_at = now();
    end if;
  end if;
  if p_pass is not null then
    if p_pass = '' then delete from public.app_secrets where name = 'ewb_pass';
    elsif length(p_pass) > 100 then raise exception 'That password is too long';
    else insert into public.app_secrets (name, value) values ('ewb_pass', p_pass) on conflict (name) do update set value = excluded.value, updated_at = now();
    end if;
  end if;
  if p_test is not null then
    insert into public.app_secrets (name, value) values ('ewb_test', case when p_test then '1' else '0' end) on conflict (name) do update set value = excluded.value, updated_at = now();
  end if;
end $$;

-- What the page may know: is it set up, is it in test mode, which username (never the key or password).
create or replace function public.ewb_api_status()
returns jsonb
language sql stable security definer set search_path = public as $$
  select case when public.my_role() in ('owner','admin','jobcards') then jsonb_build_object(
    'ready', exists (select 1 from public.app_secrets where name = 'gstinapi_key')
         and exists (select 1 from public.app_secrets where name = 'ewb_user')
         and exists (select 1 from public.app_secrets where name = 'ewb_pass'),
    'key', exists (select 1 from public.app_secrets where name = 'gstinapi_key'),
    'user', (select value from public.app_secrets where name = 'ewb_user'),
    'pass', exists (select 1 from public.app_secrets where name = 'ewb_pass'),
    'test', coalesce((select value from public.app_secrets where name = 'ewb_test'), '1') = '1')
  else jsonb_build_object('ready', false) end;
$$;

-- Sends one request to gstinapi.in and returns its answer (plus the HTTP status as "http_status").
create or replace function public.ewb_call(p_path text, p_body jsonb)
returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_key  text;
  v_user text;
  v_pass text;
  v_test boolean;
  v_res  extensions.http_response;
  v_j    jsonb;
begin
  if public.my_role() not in ('owner','admin','jobcards') then raise exception 'Not allowed'; end if;
  if p_path not in ('/v1/ewaybill', '/v1/ewaybill/cancel', '/v1/ewaybill/pdf') then raise exception 'Not allowed'; end if;
  select value into v_key from public.app_secrets where name = 'gstinapi_key';
  select value into v_user from public.app_secrets where name = 'ewb_user';
  select value into v_pass from public.app_secrets where name = 'ewb_pass';
  v_test := coalesce((select value from public.app_secrets where name = 'ewb_test'), '1') = '1';
  if v_key is null or v_user is null or v_pass is null then raise exception 'The e-way bill connection is not set up yet (⚙ Billing details)'; end if;
  if coalesce(p_body->>'gstin', '') !~ '^[0-9]{2}[A-Z]{5}[0-9]{4}[A-Z][0-9A-Z]Z[0-9A-Z]$' then raise exception 'Firstbox GSTIN is missing or wrong (⚙ Billing details)'; end if;
  begin perform extensions.http_set_curlopt('CURLOPT_TIMEOUT_MS', '60000'); exception when others then null; end;
  v_res := extensions.http((
    'POST', 'https://www.gstinapi.in' || p_path,
    array[extensions.http_header('x-api-key', v_key)],
    'application/json',
    (p_body || jsonb_build_object('gstin_username', v_user, 'password', v_pass, 'test_mode', v_test))::text
  )::extensions.http_request);
  begin v_j := v_res.content::jsonb; exception when others then
    raise exception 'The e-way bill service did not answer properly (status %). Try again in a minute.', v_res.status;
  end;
  if jsonb_typeof(v_j) <> 'object' then v_j := jsonb_build_object('success', false, 'error', v_res.content); end if;
  return v_j || jsonb_build_object('http_status', v_res.status, 'test_mode', coalesce((v_j->>'test_mode')::boolean, v_test));
end $$;

-- Owner, admin and accounts team logins.
create or replace function public.ewb_generate(p_gstin text, p_payload jsonb)
returns jsonb
language sql security definer set search_path = public as $$
  select public.ewb_call('/v1/ewaybill', jsonb_build_object('gstin', upper(trim(p_gstin)), 'payload', p_payload));
$$;

create or replace function public.ewb_cancel(p_gstin text, p_no text, p_reason text, p_remark text)
returns jsonb
language sql security definer set search_path = public as $$
  select public.ewb_call('/v1/ewaybill/cancel', jsonb_build_object('gstin', upper(trim(p_gstin)), 'ewaybill_no', trim(p_no),
    'cancel_reason_code', coalesce(nullif(trim(p_reason), ''), '2'), 'cancel_remark', left(coalesce(p_remark, ''), 50)));
$$;

-- PDF copy of an e-way bill (gstinapi.in draws it in the portal's print layout; 1 credit). Answer: {success, pdf_base64, …}.
create or replace function public.ewb_pdf(p_gstin text, p_no text)
returns jsonb
language sql security definer set search_path = public as $$
  select public.ewb_call('/v1/ewaybill/pdf', jsonb_build_object('gstin', upper(trim(p_gstin)), 'ewaybill_no', trim(p_no),
    'print_type', 'detailed', 'format', 'base64'));
$$;

revoke all on function public.set_ewb_api(text, text, text, boolean) from public, anon;
revoke all on function public.ewb_api_status() from public, anon;
revoke all on function public.ewb_call(text, jsonb) from public, anon, authenticated;
revoke all on function public.ewb_generate(text, jsonb) from public, anon;
revoke all on function public.ewb_cancel(text, text, text, text) from public, anon;
revoke all on function public.ewb_pdf(text, text) from public, anon;
grant execute on function public.set_ewb_api(text, text, text, boolean) to authenticated;
grant execute on function public.ewb_api_status() to authenticated;
grant execute on function public.ewb_generate(text, jsonb) to authenticated;
grant execute on function public.ewb_cancel(text, text, text, text) to authenticated;
grant execute on function public.ewb_pdf(text, text) to authenticated;

select 'E-way bill connection ready' as result;
