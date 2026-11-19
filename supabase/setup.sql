-- Firstbox app: database setup.
-- Paste this whole file into Supabase › SQL Editor › New query, then press Run.
-- Safe to run again: it only creates what is missing and refreshes the rules.

-- 1. Who is who. One row per login. The first person to create an account becomes the owner.
create table if not exists public.members (
  user_id    uuid primary key references auth.users(id) on delete cascade,
  email      text,
  name       text,
  role       text not null default 'pending'
             check (role in ('owner','inventory','jobcards','pending','removed')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

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
--    Job cards role: job cards + stock. Inventory role: stock (reads job cards to see what is needed).
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
);
create policy docs_insert on public.docs for insert to authenticated with check (
  public.my_role() = 'owner'
  or (public.my_role() = 'jobcards'  and col in ('jobcards','stock','stockLog'))
  or (public.my_role() = 'inventory' and col in ('stock','stockLog'))
);
create policy docs_update on public.docs for update to authenticated
  using (
    public.my_role() = 'owner'
    or (public.my_role() = 'jobcards'  and col in ('jobcards','stock','stockLog'))
    or (public.my_role() = 'inventory' and col in ('stock','stockLog'))
  )
  with check (
    public.my_role() = 'owner'
    or (public.my_role() = 'jobcards'  and col in ('jobcards','stock','stockLog'))
    or (public.my_role() = 'inventory' and col in ('stock','stockLog'))
  );
create policy docs_delete on public.docs for delete to authenticated using (
  public.my_role() = 'owner'
  or (public.my_role() = 'inventory' and col = 'stock')
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
