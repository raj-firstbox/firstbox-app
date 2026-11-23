// Test double for supabase-js v2 (only what firstbox-cloud.js uses). Data lives in localStorage
// (shared by pages in one browser context); changes are broadcast to other pages like Realtime.
(function(){
  const LS = 'fake-sb-db', AU = 'fake-sb-auth';
  const load = () => JSON.parse(localStorage.getItem(LS) || '{"users":[],"members":[],"docs":[]}');
  const save = d => localStorage.setItem(LS, JSON.stringify(d));
  const bc = new BroadcastChannel('fake-sb');
  const handlers = [];
  bc.onmessage = e => { for (const h of handlers) if (h.table === e.data.table) h.fn(e.data.payload); };
  const notify = (table, payload) => { bc.postMessage({table, payload}); for (const h of handlers) if (h.table === table) setTimeout(() => h.fn(payload), 0); };
  let session = JSON.parse(sessionStorage.getItem(AU) || 'null');
  const authCbs = [];
  const role = () => { const d = load(); const m = session && d.members.find(x => x.user_id === session.user.id); return m ? m.role : ''; };
  const canRead = (r) => role() === 'owner' || (['inventory','jobcards'].includes(role()) && ['jobcards','stock','stockLog','shared'].includes(r.col)) || (role() === 'inventory' && r.col === 'orders') || (role() === 'jobcards' && ['orders','invoices','clients','billItems','payments'].includes(r.col));
  const canWrite = (col) => role() === 'owner' || (role() === 'jobcards' && ['jobcards','stock','stockLog','orders','invoices','clients','billItems','payments'].includes(col)) || (role() === 'inventory' && ['stock','stockLog'].includes(col));
  function q(table){
    const st = {table, filters:[], op:'select', range:null, single:false};
    const api = {
      select(){ return api; }, order(){ return api; },
      eq(k, v){ st.filters.push([k, v]); return api; },
      range(a, b){ st.range = [a, b]; return api; },
      maybeSingle(){ st.single = true; return api; },
      upsert(row){ st.op = 'upsert'; st.row = row; return api; },
      update(row){ st.op = 'update'; st.row = row; return api; },
      delete(){ st.op = 'delete'; return api; },
      then(res, rej){ return Promise.resolve().then(run).then(res, rej); }
    };
    function run(){
      const d = load(); const rows = d[table];
      const match = r => st.filters.every(([k, v]) => r[k] === v);
      if (st.op === 'select'){
        let out = rows.filter(match);
        if (table === 'docs') out = out.filter(canRead);
        if (table === 'members') out = out.filter(r => role() === 'owner' || (session && r.user_id === session.user.id));
        if (st.range) out = out.slice(st.range[0], st.range[1] + 1);
        return {data: st.single ? (out[0] || null) : out, error: null};
      }
      if (table === 'docs' && !canWrite(st.op === 'upsert' ? st.row.col : (st.filters.find(f => f[0] === 'col') || [])[1])) return {data:null, error:{message:'new row violates row-level security policy'}};
      if (st.op === 'upsert'){ const i = rows.findIndex(r => r.col === st.row.col && r.id === st.row.id); const ev = i < 0 ? 'INSERT' : 'UPDATE'; if (i < 0) rows.push(st.row); else rows[i] = st.row; save(d); notify(table, {eventType: ev, new: st.row, old: {}}); return {data:null, error:null}; }
      if (st.op === 'update'){ if (table === 'members' && role() !== 'owner') return {data:null, error:null}; rows.filter(match).forEach(r => { Object.assign(r, st.row); notify(table, {eventType:'UPDATE', new:r, old:{}}); }); save(d); return {data:null, error:null}; }
      if (st.op === 'delete'){ const gone = rows.filter(match); d[table] = rows.filter(r => !match(r)); save(d); gone.forEach(r => notify(table, {eventType:'DELETE', new:{}, old:{col:r.col, id:r.id}})); return {data:null, error:null}; }
    }
    return api;
  }
  function setSession(s, ev){ session = s; sessionStorage.setItem(AU, JSON.stringify(s)); for (const cb of authCbs) cb(ev, s); }
  window.supabase = { createClient(url, key){
    return {
      auth: {
        async getSession(){ return {data:{session}}; },
        onAuthStateChange(cb){ authCbs.push(cb); return {data:{subscription:{unsubscribe(){}}}}; },
        async signUp({email, password, options}){
          const d = load(); if (d.users.find(u => u.email === email)) return {data:{}, error:{message:'User already registered'}};
          const id = 'u-' + Math.random().toString(36).slice(2, 10);
          d.users.push({id, email, password});
          d.members.push({user_id:id, email, name:(options && options.data && options.data.name) || '', role: d.members.some(m => m.role === 'owner') ? 'pending' : 'owner', created_at:new Date().toISOString()});
          save(d); notify('members', {eventType:'INSERT', new:{}, old:{}});
          const s = {user:{id, email}}; setSession(s, 'SIGNED_IN'); return {data:{session:s}, error:null};
        },
        async signInWithPassword({email, password}){
          const u = load().users.find(x => x.email === email && x.password === password);
          if (!u) return {data:{}, error:{message:'Invalid login credentials'}};
          const s = {user:{id:u.id, email}}; setSession(s, 'SIGNED_IN'); return {data:{session:s}, error:null};
        },
        async signOut(){ setSession(null, 'SIGNED_OUT'); return {error:null}; }
      },
      from: q,
      async rpc(name, args){ const d = load();
        if (name === 'create_member'){ if (role() !== 'owner') return {error:{message:'Only the owner can add team members'}};
          const u = String(args.p_username).toLowerCase(); if (d.members.some(m => m.username === u)) return {error:{message:'P0001: The username "' + u + '" is already taken'}};
          const id = 'u-' + Math.random().toString(36).slice(2, 10); d.users.push({id, email: u + '@firstbox.local', password: args.p_password});
          d.members.push({user_id:id, email:u + '@firstbox.local', name:args.p_name, username:u, role:args.p_role, created_at:new Date().toISOString()}); save(d); notify('members', {eventType:'INSERT', new:{}, old:{}}); return {data:id, error:null}; }
        if (name === 'set_gst_api_key'){ if (role() !== 'owner') return {error:{message:'Only the owner can set the GST lookup key'}}; d.gstKey = args.p_key || null; save(d); return {data:null, error:null}; }
        if (name === 'gst_key_set'){ return {data: !!d.gstKey && ['owner','jobcards'].includes(role()), error:null}; }
        if (name === 'gst_lookup'){ if (!['owner','jobcards'].includes(role())) return {error:{message:'Not allowed'}}; if (!d.gstKey) return {error:{message:'P0001: GST lookup is not set up yet'}};
          return {data:{gstin:args.p_gstin, lgnm:'SAMPLE TRADERS PRIVATE LIMITED', tradeNam:'SAMPLE TRADERS', sts:'Active', pradr:{addr:{bno:'12', bnm:'Test Building', st:'Main Road', loc:'Gurugram', dst:'Gurugram', stcd:'Haryana', pncd:'122001'}}}, error:null}; }
        if (name === 'set_member_password'){ if (role() !== 'owner') return {error:{message:'no'}}; const us = d.users.find(x => x.id === args.p_user); us.password = args.p_password; save(d); return {data:null, error:null}; }
        if (name === 'delete_member'){ if (role() !== 'owner') return {error:{message:'no'}}; d.users = d.users.filter(x => x.id !== args.p_user); d.members = d.members.filter(x => x.user_id !== args.p_user); save(d); notify('members', {eventType:'DELETE', new:{}, old:{}}); return {data:null, error:null}; } const m = d.members.find(x => session && x.user_id === session.user.id); if (m && ['removed','pending'].includes(m.role)){ m.role = 'pending'; if (args.p_name) m.name = args.p_name; save(d); notify('members', {eventType:'UPDATE', new:m, old:{}}); } return {data:null, error:null}; },
      channel(){ const ch = { on(kind, opt, fn){ handlers.push({table: opt.table, fn}); return ch; }, subscribe(cb){ setTimeout(() => cb('SUBSCRIBED'), 5); return ch; } }; return ch; }
    };
  } };
})();
