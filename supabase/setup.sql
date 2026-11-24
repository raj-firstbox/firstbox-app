-- Firstbox app: database setup.
-- Paste this whole file into Supabase › SQL Editor › New query, then press Run.
-- Safe to run again: it only creates what is missing and refreshes the rules.

-- 1. Who is who. One row per login. The first person to create an account becomes the owner.
create table if not exists public.members (
  user_id    uuid primary key references auth.users(id) on delete cascade,
  email      text,
  name       text,
  role       text not null default 'pending'
             check (role in ('owner','inventory','jobcards','sales','pending','removed')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- The Sales team role (added Nov 2026): widen the allowed roles on an existing table too.
alter table public.members drop constraint if exists members_role_check;
alter table public.members add constraint members_role_check check (role in ('owner','inventory','jobcards','sales','pending','removed'));

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

-- 6. Rules. Costings, rates, price history and settings: owner only.
--    Job cards role: job cards + stock + client POs (orders; PO rates in poRates stay owner only) + invoices, the client list and saved invoice items. Inventory role: stock (reads job cards to see what is needed).
alter table public.members enable row level security;
alter table public.docs    enable row level security;

drop policy if exists members_read   on public.members;
drop policy if exists members_update on public.members;
drop policy if exists members_delete on public.members;
create policy members_read   on public.members for select to authenticated
  using (user_id = auth.uid() or public.my_role() = 'owner');
create policy members_update on public.members for update to authenticated
  using (public.my_role() = 'owner' and user_id <> auth.uid())
  with check (public.my_role() = 'owner' and role <> 'owner');
create policy members_delete on public.members for delete to authenticated
  using (public.my_role() = 'owner' and user_id <> auth.uid());

drop policy if exists docs_read   on public.docs;
drop policy if exists docs_insert on public.docs;
drop policy if exists docs_update on public.docs;
drop policy if exists docs_delete on public.docs;
create policy docs_read on public.docs for select to authenticated using (
  public.my_role() = 'owner'
  or (public.my_role() in ('inventory','jobcards') and col in ('jobcards','stock','stockLog','shared'))
  or (public.my_role() = 'inventory' and col = 'orders')   -- the stock team sees the running orders list (read only)
  or (public.my_role() in ('inventory','jobcards') and col in ('samples','samplePics'))   -- samples (and their photos): the whole team sees them
  or (public.my_role() = 'jobcards' and col in ('orders','invoices','clients','billItems','payments'))
  -- sales team: clients & leads, samples, running orders (+ job cards to group them), Database without costs (pastwork + priceBook), shared lists
  or (public.my_role() = 'sales' and col in ('leads','samples','samplePics','orders','jobcards','pastwork','priceBook','shared'))
);
create policy docs_insert on public.docs for insert to authenticated with check (
  public.my_role() = 'owner'
  or (public.my_role() = 'jobcards'  and col in ('jobcards','stock','stockLog','orders','invoices','clients','billItems','payments','samples','samplePics'))
  or (public.my_role() = 'inventory' and col in ('stock','stockLog','samples'))   -- (saving is insert-or-update)
  or (public.my_role() = 'sales'     and col in ('leads','samples','samplePics'))
);
create policy docs_update on public.docs for update to authenticated
  using (
    public.my_role() = 'owner'
    or (public.my_role() = 'jobcards'  and col in ('jobcards','stock','stockLog','orders','invoices','clients','billItems','payments','samples','samplePics'))
    or (public.my_role() = 'inventory' and col in ('stock','stockLog','samples'))   -- stock team can mark a sample ready
    or (public.my_role() = 'sales'     and col in ('leads','samples','samplePics'))
  )
  with check (
    public.my_role() = 'owner'
    or (public.my_role() = 'jobcards'  and col in ('jobcards','stock','stockLog','orders','invoices','clients','billItems','payments','samples','samplePics'))
    or (public.my_role() = 'inventory' and col in ('stock','stockLog','samples'))   -- stock team can mark a sample ready
    or (public.my_role() = 'sales'     and col in ('leads','samples','samplePics'))
  );
create policy docs_delete on public.docs for delete to authenticated using (
  public.my_role() = 'owner'
  or (public.my_role() = 'inventory' and col = 'stock')
  or (public.my_role() in ('jobcards','inventory','sales') and col = 'samplePics')   -- photos go when a sample is marked ready (anyone can mark it)
);

grant select, insert, update, delete on public.docs to authenticated;
grant select, update, delete on public.members to authenticated;
grant execute on function public.my_role() to authenticated;
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

-- Owner adds a team member. Returns the new member's id.
create or replace function public.create_member(p_username text, p_password text, p_name text, p_role text)
returns uuid
language plpgsql security definer set search_path = public, extensions, auth as $$
declare
  v_user  text := lower(trim(p_username));
  v_email text := public.login_email(p_username);
  v_id    uuid := gen_random_uuid();
  v_now   timestamptz := now();
begin
  if public.my_role() <> 'owner' then raise exception 'Only the owner can add team members'; end if;
  if v_user !~ '^[a-z0-9][a-z0-9._-]{2,29}$' then raise exception 'Username: 3 to 30 letters or numbers (dots, dashes allowed), no spaces'; end if;
  if length(coalesce(p_password, '')) < 8 then raise exception 'Password: at least 8 characters'; end if;
  if p_role not in ('inventory', 'jobcards', 'sales') then raise exception 'Choose Inventory, Job cards or Sales team'; end if;
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

-- Owner sets a new password for a team member (e.g. they forgot it).
create or replace function public.set_member_password(p_user uuid, p_password text) returns void
language plpgsql security definer set search_path = public, extensions, auth as $$
begin
  if public.my_role() <> 'owner' then raise exception 'Only the owner can change passwords'; end if;
  if p_user = auth.uid() then raise exception 'Change your own password from Supabase'; end if;
  if length(coalesce(p_password, '')) < 8 then raise exception 'Password: at least 8 characters'; end if;
  update auth.users set encrypted_password = crypt(p_password, gen_salt('bf')), updated_at = now() where id = p_user;
  if not found then raise exception 'Team member not found'; end if;
end $$;

-- Owner removes a team member's login completely (their username can then be used again).
create or replace function public.delete_member(p_user uuid) returns void
language plpgsql security definer set search_path = public, auth as $$
begin
  if public.my_role() <> 'owner' then raise exception 'Only the owner can remove team members'; end if;
  if p_user = auth.uid() then raise exception 'You cannot remove yourself'; end if;
  delete from auth.users where id = p_user;
end $$;

revoke all on function public.create_member(text, text, text, text) from public, anon;
revoke all on function public.set_member_password(uuid, text) from public, anon;
revoke all on function public.delete_member(uuid) from public, anon;
grant execute on function public.create_member(text, text, text, text) to authenticated;
grant execute on function public.set_member_password(uuid, text) to authenticated;
grant execute on function public.delete_member(uuid) to authenticated;

