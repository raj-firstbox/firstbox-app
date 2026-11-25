-- Firstbox app: let the accounts team keep delivery photos (signed receiving copies) on tax invoices and challans.
-- Same rules as before, plus the podPics collection for the accounts team. Safe to run again.
drop policy if exists docs_read   on public.docs;
drop policy if exists docs_insert on public.docs;
drop policy if exists docs_update on public.docs;
drop policy if exists docs_delete on public.docs;
create policy docs_read on public.docs for select to authenticated using (
  public.is_admin()
  or (public.my_role() = 'jobcards'  and col in ('jobcards','stock','stockLog','shared','orders','invoices','clients','billItems','payments','podPics'))
  or (public.my_role() = 'sales'     and col in ('leads','samples','samplePics','orders','jobcards','pastwork','priceBook','shared'))
  or (public.my_role() = 'manager'   and col in ('jobcards','stock','stockLog','shared','orders','samples','samplePics','leads','pastwork','priceBook'))
  or (public.my_role() = 'inventory' and col in ('jobcards','stock','stockLog','shared','orders','samples','samplePics'))
);
create policy docs_insert on public.docs for insert to authenticated with check (
  public.is_admin()
  or (public.my_role() = 'jobcards'  and col in ('jobcards','stock','stockLog','orders','invoices','clients','billItems','payments','podPics'))
  or (public.my_role() = 'sales'     and col in ('leads','samples','samplePics'))
  or (public.my_role() = 'inventory' and col in ('stock','stockLog','samples'))   -- (saving is insert-or-update)
);
create policy docs_update on public.docs for update to authenticated
  using (
    public.is_admin()
    or (public.my_role() = 'jobcards'  and col in ('jobcards','stock','stockLog','orders','invoices','clients','billItems','payments','podPics'))
    or (public.my_role() = 'sales'     and col in ('leads','samples','samplePics'))
    or (public.my_role() = 'inventory' and col in ('stock','stockLog','samples'))   -- stock team can mark a sample ready
  )
  with check (
    public.is_admin()
    or (public.my_role() = 'jobcards'  and col in ('jobcards','stock','stockLog','orders','invoices','clients','billItems','payments','podPics'))
    or (public.my_role() = 'sales'     and col in ('leads','samples','samplePics'))
    or (public.my_role() = 'inventory' and col in ('stock','stockLog','samples'))
  );
create policy docs_delete on public.docs for delete to authenticated using (
  public.is_admin()
  or (public.my_role() = 'inventory' and col = 'stock')
  or (public.my_role() in ('inventory','sales') and col = 'samplePics')   -- photos go when a sample is marked ready
  or (public.my_role() = 'jobcards' and col = 'podPics')                -- delivery photos (signed receiving copy) can be replaced
);

select 'Delivery photos ready' as result;
