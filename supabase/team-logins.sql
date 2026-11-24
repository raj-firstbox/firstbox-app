-- Firstbox: logins created by the owner (username + password). No self sign-up.
-- Paste into Supabase › SQL Editor › New query, then press Run. Safe to run again.

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

select 'Team logins ready' as result;
