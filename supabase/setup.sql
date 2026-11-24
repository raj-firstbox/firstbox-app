-- Firstbox app: database setup.
-- Paste this whole file into Supabase › SQL Editor › New query, then press Run.
-- Safe to run again: it only creates what is missing and refreshes the rules.

-- 1. Who is who. One row per login. The first person to create an account becomes the owner.
create table if not exists public.members (
  user_id    uuid primary key references auth.users(id) on delete cascade,
  email      text,
  name       text,
  role       text not null default 'pending'
             check (role in ('owner','admin','manager','inventory','jobcards','sales','pending','removed')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- The Sales team role (added Nov 2026): widen the allowed roles on an existing table too.
alter table public.members drop constraint if exists members_role_check;
alter table public.members add constraint members_role_check check (role in ('owner','admin','manager','inventory','jobcards','sales','pending','removed'));

-- 2. All app data, stored as small JSON documents grouped by collection
--    (jobs, rates, rateHistory, config, jobcards, stock, stockLog, shared).
create table if not exists public.docs (
  col        text not null,
  id         text not null,
  data       jsonb not null default '{}'::jsonb,
  updated_at timestamptz not null default now(),
  updated_by uuid default auth.uid(),
  primary key (col, id)
);

-- 3. The signed-in person's role ('' when not signed in or not a member).
create or replace function public.my_role() returns text
language sql stable security definer set search_path = public as $$
  select coalesce((select role from public.members where user_id = auth.uid()), '');
$$;
-- Owner or admin: full control.
create or replace function public.is_admin() returns boolean
language sql stable security definer set search_path = public as $$
  select public.my_role() in ('owner','admin');
$$;

-- 4. New account → member row. First account ever = owner; everyone after waits for approval.
create or replace function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  perform pg_advisory_xact_lock(42);
  insert into public.members (user_id, email, name, role)
  values (new.id, new.email, coalesce(new.raw_user_meta_data->>'name', ''),
          case when exists (select 1 from public.members where role = 'owner') then 'pending' else 'owner' end)
  on conflict (user_id) do nothing;
  return new;
end $$;
drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created after insert on auth.users
  for each row execute function public.handle_new_user();

-- 5. Someone without access asks for it again (after being removed or declined).
create or replace function public.request_access(p_name text) returns void
language plpgsql security definer set search_path = public as $$
begin
  update public.members
     set name = left(coalesce(nullif(trim(p_name), ''), name), 60),
         role = case when role in ('removed','pending') then 'pending' else role end,
         updated_at = now()
   where user_id = auth.uid();
end $$;

-- 6. Rules (Nov 2026).
--    Owner + admin: everything. Costings, rates, price history, settings and PO rates stay with them only.
--    Accounts team (role jobcards): job cards, running orders + client POs (orders), billing (invoices, clients, billItems, payments), stock — read and write.
--    Sales team: Sales & marketing (leads), samples (+ photos) — read and write; running orders, job cards (to group them), Database without costs — read only.
--    Manager: read only — job cards, samples, Sales & marketing, running orders, stock, Database without costs. No costings, client POs pages or billing.
--    Stock team (role inventory): stock — read and write; job cards, running orders, samples — read; can mark samples ready.
alter table public.members enable row level security;
alter table public.docs    enable row level security;

drop policy if exists members_read   on public.members;
drop policy if exists members_update on public.members;
drop policy if exists members_delete on public.members;
create policy members_read   on public.members for select to authenticated
  using (user_id = auth.uid() or public.is_admin());
-- owner/admin change other people's roles, never their own and never the owner's
create policy members_update on public.members for update to authenticated
  using (public.is_admin() and user_id <> auth.uid() and role <> 'owner')
  with check (public.is_admin() and role <> 'owner');
create policy members_delete on public.members for delete to authenticated
  using (public.is_admin() and user_id <> auth.uid() and role <> 'owner');

drop policy if exists docs_read   on public.docs;
drop policy if exists docs_insert on public.docs;
drop policy if exists docs_update on public.docs;
drop policy if exists docs_delete on public.docs;
create policy docs_read on public.docs for select to authenticated using (
  public.is_admin()
  or (public.my_role() = 'jobcards'  and col in ('jobcards','stock','stockLog','shared','orders','invoices','clients','billItems','payments'))
  or (public.my_role() = 'sales'     and col in ('leads','samples','samplePics','orders','jobcards','pastwork','priceBook','shared'))
  or (public.my_role() = 'manager'   and col in ('jobcards','stock','stockLog','shared','orders','samples','samplePics','leads','pastwork','priceBook'))
  or (public.my_role() = 'inventory' and col in ('jobcards','stock','stockLog','shared','orders','samples','samplePics'))
);
create policy docs_insert on public.docs for insert to authenticated with check (
  public.is_admin()
  or (public.my_role() = 'jobcards'  and col in ('jobcards','stock','stockLog','orders','invoices','clients','billItems','payments'))
  or (public.my_role() = 'sales'     and col in ('leads','samples','samplePics'))
  or (public.my_role() = 'inventory' and col in ('stock','stockLog','samples'))   -- (saving is insert-or-update)
);
create policy docs_update on public.docs for update to authenticated
  using (
    public.is_admin()
    or (public.my_role() = 'jobcards'  and col in ('jobcards','stock','stockLog','orders','invoices','clients','billItems','payments'))
    or (public.my_role() = 'sales'     and col in ('leads','samples','samplePics'))
    or (public.my_role() = 'inventory' and col in ('stock','stockLog','samples'))   -- stock team can mark a sample ready
  )
  with check (
    public.is_admin()
    or (public.my_role() = 'jobcards'  and col in ('jobcards','stock','stockLog','orders','invoices','clients','billItems','payments'))
    or (public.my_role() = 'sales'     and col in ('leads','samples','samplePics'))
    or (public.my_role() = 'inventory' and col in ('stock','stockLog','samples'))
  );
create policy docs_delete on public.docs for delete to authenticated using (
  public.is_admin()
  or (public.my_role() = 'inventory' and col = 'stock')
  or (public.my_role() in ('inventory','sales') and col = 'samplePics')   -- photos go when a sample is marked ready
);

grant select, insert, update, delete on public.docs to authenticated;
grant select, update, delete on public.members to authenticated;
grant execute on function public.my_role() to authenticated;
grant execute on function public.is_admin() to authenticated;
grant execute on function public.request_access(text) to authenticated;

-- 7. Live updates: every open app sees changes within seconds.
do $$ begin
  if not exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and tablename = 'docs') then
    alter publication supabase_realtime add table public.docs;
  end if;
  if not exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and tablename = 'members') then
    alter publication supabase_realtime add table public.members;
  end if;
end $$;

select 'Firstbox setup done' as result;

-- ===== Logins created by the owner (same as team-logins.sql) =====

create extension if not exists pgcrypto with schema extensions;

alter table public.members add column if not exists username text;
create unique index if not exists members_username_key on public.members (lower(username));

-- Team members sign in with a username. Behind the scenes it is stored as <username>@firstbox.local
-- (Supabase logins need an email-shaped name; nothing is ever sent to it).
create or replace function public.login_email(p_username text) returns text
language sql immutable as $$ select lower(trim(p_username)) || '@firstbox.local' $$;

-- Owner or admin adds a team member. Returns the new member's id.
create or replace function public.create_member(p_username text, p_password text, p_name text, p_role text)
returns uuid
language plpgsql security definer set search_path = public, extensions, auth as $$
declare
  v_user  text := lower(trim(p_username));
  v_email text := public.login_email(p_username);
  v_id    uuid := gen_random_uuid();
  v_now   timestamptz := now();
begin
  if not public.is_admin() then raise exception 'Only the owner or an admin can add team members'; end if;
  if v_user !~ '^[a-z0-9][a-z0-9._-]{2,29}$' then raise exception 'Username: 3 to 30 letters or numbers (dots, dashes allowed), no spaces'; end if;
  if length(coalesce(p_password, '')) < 8 then raise exception 'Password: at least 8 characters'; end if;
  if p_role not in ('jobcards', 'sales', 'manager', 'inventory', 'admin') then raise exception 'Choose Accounts team, Sales team, Manager, Stock team or Admin'; end if;
  if exists (select 1 from auth.users where lower(email) = v_email)
     or exists (select 1 from public.members where lower(username) = v_user) then
    raise exception 'The username "%" is already taken', v_user;
  end if;

  insert into auth.users (instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
                          raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
                          confirmation_token, recovery_token, email_change_token_new, email_change)
  values ('00000000-0000-0000-0000-000000000000', v_id, 'authenticated', 'authenticated', v_email,
          crypt(p_password, gen_salt('bf')), v_now,
          '{"provider":"email","providers":["email"]}'::jsonb,
          jsonb_build_object('name', left(coalesce(p_name, ''), 60), 'username', v_user),
          v_now, v_now, '', '', '', '');

  insert into auth.identities (id, user_id, provider_id, provider, identity_data, last_sign_in_at, created_at, updated_at)
  values (gen_random_uuid(), v_id, v_id::text, 'email',
          jsonb_build_object('sub', v_id::text, 'email', v_email, 'email_verified', true, 'phone_verified', false),
          v_now, v_now, v_now);

  -- the sign-up trigger has made a waiting member row; give it the name, username and role
  insert into public.members (user_id, email, name, role) values (v_id, v_email, '', 'pending') on conflict (user_id) do nothing;
  update public.members
     set name = left(coalesce(nullif(trim(p_name), ''), v_user), 60), username = v_user, role = p_role, updated_at = now()
   where user_id = v_id;
  return v_id;
end $$;

-- Owner or admin sets a new password for a team member (e.g. they forgot it). Nobody can change the owner's this way.
create or replace function public.set_member_password(p_user uuid, p_password text) returns void
language plpgsql security definer set search_path = public, extensions, auth as $$
begin
  if not public.is_admin() then raise exception 'Only the owner or an admin can change passwords'; end if;
  if p_user = auth.uid() then raise exception 'Change your own password from Supabase'; end if;
  if exists (select 1 from public.members where user_id = p_user and role = 'owner') then raise exception 'The owner''s password cannot be changed here'; end if;
  if length(coalesce(p_password, '')) < 8 then raise exception 'Password: at least 8 characters'; end if;
  update auth.users set encrypted_password = crypt(p_password, gen_salt('bf')), updated_at = now() where id = p_user;
  if not found then raise exception 'Team member not found'; end if;
end $$;

-- Owner or admin removes a team member's login completely (their username can then be used again). Never the owner.
create or replace function public.delete_member(p_user uuid) returns void
language plpgsql security definer set search_path = public, auth as $$
begin
  if not public.is_admin() then raise exception 'Only the owner or an admin can remove team members'; end if;
  if p_user = auth.uid() then raise exception 'You cannot remove yourself'; end if;
  if exists (select 1 from public.members where user_id = p_user and role = 'owner') then raise exception 'The owner cannot be removed'; end if;
  delete from auth.users where id = p_user;
end $$;

revoke all on function public.create_member(text, text, text, text) from public, anon;
revoke all on function public.set_member_password(uuid, text) from public, anon;
revoke all on function public.delete_member(uuid) from public, anon;
grant execute on function public.create_member(text, text, text, text) to authenticated;
grant execute on function public.set_member_password(uuid, text) to authenticated;
grant execute on function public.delete_member(uuid) to authenticated;

