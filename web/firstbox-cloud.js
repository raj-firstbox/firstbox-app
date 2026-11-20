/* Firstbox cloud connector.
 * The Firstbox page was first built inside Claude, where it talks to `window.claude.use('db' | 'user' | 'downloads')`.
 * Outside Claude (the Mac / Windows app, or a browser) this file provides the same three things on top of Supabase:
 *   db        → documents in the `docs` table (live updates), plus the team list from `members`
 *   user      → the signed-in person and their role
 *   downloads → saves PDFs into Documents/Firstbox on a computer running the app, or a normal download in a browser
 * It also shows the sign-in / create-account screen. */
(function () {
  'use strict';
  if (window.claude) return; // running inside Claude: the platform provides everything
  window.FIRSTBOX_CLOUD = true;

  const cfg = window.FIRSTBOX_CONFIG || {};
  const desktop = window.firstboxDesktop || null;
  const STAFF = ['inventory', 'jobcards'];
  const VIRTUAL = ['team', 'requests'];

  let sb = null, session = null, me = null;
  const docs = new Map();          // col -> Map(id -> data)
  const colLoaded = new Map();     // col -> Promise
  const listeners = new Map();     // col -> Set(fn)
  let members = new Map();         // user_id -> row
  let membersLoaded = null;
  let ready, resolveReady;
  ready = new Promise(r => (resolveReady = r));

  const err = (code, message) => Object.assign(new Error(message || code), { code });
  const toMs = t => (t ? new Date(t).getTime() : Date.now());

  // ---------- sign-in screen ----------
  function css() {
    if (document.getElementById('fbc-css')) return;
    const s = document.createElement('style');
    s.id = 'fbc-css';
    s.textContent = `
      #fbc-auth{position:fixed;inset:0;z-index:100;background:#FFF8F3;display:grid;place-items:center;padding:16px;overflow:auto;font-family:"IBM Plex Sans",system-ui,-apple-system,"Segoe UI",sans-serif;color:#1F1A16}
      #fbc-auth .box{width:100%;max-width:400px;background:#fff;border:1px solid #EADFD6;border-top:4px solid #EB6123;border-radius:10px;padding:24px;display:grid;gap:14px;box-shadow:0 10px 30px rgba(31,26,22,.08)}
      #fbc-auth img{height:46px;width:auto;justify-self:start}
      #fbc-auth h1{font-size:20px;margin:0}
      #fbc-auth .tabs{display:flex;gap:6px;background:#F6EEE8;padding:4px;border-radius:8px}
      #fbc-auth .tabs button{flex:1;border:0;background:none;padding:8px;border-radius:6px;font:inherit;font-weight:600;color:#6B6058;cursor:pointer}
      #fbc-auth .tabs button[aria-pressed="true"]{background:#fff;color:#B8470F;box-shadow:0 1px 3px rgba(0,0,0,.08)}
      #fbc-auth label{display:grid;gap:4px;font-size:12px;font-weight:600;letter-spacing:.04em;text-transform:uppercase;color:#6B6058}
      #fbc-auth input{font:inherit;font-size:15px;text-transform:none;letter-spacing:0;color:#1F1A16;padding:10px 12px;border:1px solid #D9CCC2;border-radius:6px;background:#fff}
      #fbc-auth input:focus{outline:2px solid #EB6123;outline-offset:0;border-color:#EB6123}
      #fbc-auth .go{border:0;background:#D9531C;color:#fff;font:inherit;font-weight:700;font-size:15px;padding:11px;border-radius:6px;cursor:pointer}
      #fbc-auth .go:disabled{opacity:.6;cursor:default}
      #fbc-auth .msg{font-size:14px;padding:10px 12px;border-radius:6px;background:#FBF1D2;color:#5C4400}
      #fbc-auth .msg.err{background:#FDE8E6;color:#8A1C12}
      #fbc-auth .note{font-size:13px;color:#6B6058}
      #fbc-signout{border:1px solid #EADFD6;background:#fff;color:#6B6058;border-radius:8px;padding:8px 12px;font:inherit;font-size:13px;font-weight:600;cursor:pointer;white-space:nowrap}
      #fbc-signout:hover{color:#B8470F;border-color:#EB6123}
      #fbc-net{position:fixed;left:50%;bottom:16px;transform:translateX(-50%);z-index:90;background:#1F1A16;color:#fff;padding:10px 16px;border-radius:8px;font:14px "IBM Plex Sans",system-ui,sans-serif;box-shadow:0 6px 20px rgba(0,0,0,.2)}
      #fbc-net[hidden]{display:none}`;
    document.head.append(s);
  }
  function el(tag, attrs, ...kids) {
    const e = document.createElement(tag);
    for (const [k, v] of Object.entries(attrs || {})) {
      if (v == null) continue;
      if (k.startsWith('on')) e.addEventListener(k.slice(2), v); else e.setAttribute(k, v);
    }
    for (const k of kids.flat()) if (k != null) e.append(k.nodeType ? k : document.createTextNode(String(k)));
    return e;
  }
  function logoSrc() { const l = document.getElementById('logo'); return l ? l.src : ''; }

  // Logins are created by the owner (Team & access). Team members sign in with a username;
  // the owner can also use the email address the owner account was made with.
  const loginEmail = v => (v.includes('@') ? v : v.toLowerCase() + '@firstbox.local');
  function showAuth(mode, note) {
    css();
    let root = document.getElementById('fbc-auth');
    if (!root) { root = el('div', { id: 'fbc-auth', role: 'dialog', 'aria-modal': 'true', 'aria-label': 'Sign in to Firstbox' }); document.body.append(root); }
    const user = el('input', { type: 'text', autocomplete: 'username', autocapitalize: 'off', spellcheck: 'false', placeholder: 'e.g. ramesh' });
    const pass = el('input', { type: 'password', autocomplete: 'current-password' });
    const msg = el('div', {});
    const btn = el('button', { class: 'go', type: 'submit' }, 'Sign in');
    const say = (t, bad) => msg.replaceChildren(t ? el('div', { class: 'msg' + (bad ? ' err' : '') }, t) : '');
    if (note) say(note.text, note.bad);
    const form = el('form', { style: 'display:grid;gap:12px', novalidate: '' },
      el('label', {}, 'Username (owner: your email)', user),
      el('label', {}, 'Password', pass),
      msg, btn);
    form.addEventListener('submit', async e => {
      e.preventDefault();
      const u = user.value.trim(), pw = pass.value;
      if (!u) { say('Enter your username.', true); user.focus(); return; }
      if (!pw) { say('Enter your password.', true); pass.focus(); return; }
      btn.disabled = true; btn.textContent = 'Signing in…';
      try {
        const { error } = await sb.auth.signInWithPassword({ email: loginEmail(u), password: pw });
        if (error) throw error;
        // onAuthStateChange takes it from here.
      } catch (x) {
        const m = String((x && x.message) || x);
        say(/invalid login|invalid credentials/i.test(m) ? 'Username or password is wrong.' :
            /not confirmed/i.test(m) ? 'This login is not active yet. Ask the owner.' :
            /fetch|network/i.test(m) ? 'No internet connection. Connect and try again.' : m, true);
        btn.disabled = false; btn.textContent = 'Sign in';
      }
    });
    root.replaceChildren(el('div', { class: 'box' },
      el('img', { src: logoSrc(), alt: 'Firstbox' }),
      el('h1', {}, 'Sign in to Firstbox'),
      form,
      el('div', { class: 'note' }, 'Team: your username and password are given to you by the owner. Owner: sign in with your full email address.')));
    setTimeout(() => user.focus(), 30);
  }
  function hideAuth() { const r = document.getElementById('fbc-auth'); if (r) r.remove(); }

  function addSignOut() {
    if (document.getElementById('fbc-signout')) return;
    const wrap = document.querySelector('.bar .wrap');
    if (!wrap) return;
    const b = el('button', { id: 'fbc-signout', type: 'button', title: session ? 'Signed in as ' + session.user.email : '' }, 'Sign out');
    b.addEventListener('click', async () => { b.disabled = true; try { await sb.auth.signOut(); } catch (e) {} location.reload(); });
    wrap.append(b);
  }
  function netBanner(on, text) {
    css();
    let b = document.getElementById('fbc-net');
    if (!b) { b = el('div', { id: 'fbc-net', role: 'status' }); b.hidden = true; document.body.append(b); }
    b.textContent = text || 'No internet connection. Changes will not sync until you are back online.';
    b.hidden = !on;
  }
  window.addEventListener('offline', () => netBanner(true));
  window.addEventListener('online', () => { netBanner(false); refreshAll(); });

  // ---------- data ----------
  function emit(col) {
    const set = listeners.get(col);
    if (set) for (const fn of [...set]) { try { fn(); } catch (e) { console.error(e); } }
  }
  async function fetchCol(col) {
    const out = new Map();
    for (let from = 0; ; from += 1000) {
      const { data, error } = await sb.from('docs').select('id,data').eq('col', col).order('id').range(from, from + 999);
      if (error) throw err('unavailable', error.message);
      for (const r of data) out.set(r.id, r.data);
      if (data.length < 1000) break;
    }
    docs.set(col, out);
    emit(col);
  }
  function loadCol(col) {
    if (!colLoaded.has(col)) colLoaded.set(col, fetchCol(col).catch(e => { colLoaded.delete(col); throw e; }));
    return colLoaded.get(col);
  }
  let memSeq = 0, memTimer = null;
  async function fetchMembers() {
    const mine = ++memSeq;
    const { data, error } = await sb.from('members').select('user_id,email,name,role,created_at,username');
    if (mine !== memSeq) return; // a newer read is on its way
    if (error) throw err('unavailable', error.message);
    members = new Map(data.map(r => [r.user_id, r]));
    if (session) me = members.get(session.user.id) || me;
    emit('team'); emit('requests'); emit('__me');
  }
  function loadMembers() {
    if (!membersLoaded) membersLoaded = fetchMembers().catch(e => { membersLoaded = null; throw e; });
    return membersLoaded;
  }
  async function refreshAll() {
    try {
      await Promise.all([...colLoaded.keys()].map(c => fetchCol(c)).concat(fetchMembers()));
    } catch (e) { /* stay on what we have; the banner explains */ }
  }
  let channel = null;
  function startRealtime() {
    if (channel) return;
    channel = sb.channel('firstbox-live')
      .on('postgres_changes', { event: '*', schema: 'public', table: 'docs' }, p => {
        const row = p.eventType === 'DELETE' ? p.old : p.new;
        if (!row || !row.col || !docs.has(row.col)) return;
        const m = docs.get(row.col);
        if (p.eventType === 'DELETE') m.delete(row.id); else m.set(row.id, row.data);
        emit(row.col);
      })
      .on('postgres_changes', { event: '*', schema: 'public', table: 'members' }, () => { clearTimeout(memTimer); memTimer = setTimeout(() => fetchMembers().catch(() => {}), 150); })
      .subscribe(status => {
        if (status === 'SUBSCRIBED') { netBanner(false); refreshAll(); }
        else if (status === 'CHANNEL_ERROR' || status === 'TIMED_OUT') netBanner(true, 'Live updates paused. Reconnecting…');
      });
  }

  // Team list and access requests come from `members`, shaped like the documents the page expects.
  function virtualDocs(col) {
    const out = new Map();
    for (const r of members.values()) {
      if (col === 'team' && STAFF.includes(r.role)) out.set(r.user_id, { role: r.role, label: r.name || r.username || r.email || '', username: r.username || '', addedAt: toMs(r.created_at) });
      if (col === 'requests' && r.role === 'pending') out.set(r.user_id, { label: r.name || r.email || '', at: toMs(r.created_at) });
    }
    return out;
  }
  function colMap(col) { return VIRTUAL.includes(col) ? virtualDocs(col) : (docs.get(col) || new Map()); }
  const snapDoc = (id, d) => ({ id, exists: d !== undefined, data: () => (d === undefined ? undefined : JSON.parse(JSON.stringify(d))), metadata: { fromCache: false } });

  function subscribe(col, fn, onErr) {
    const key = VIRTUAL.includes(col) ? col : col;
    if (!listeners.has(key)) listeners.set(key, new Set());
    listeners.get(key).add(fn);
    const p = VIRTUAL.includes(col) ? loadMembers() : loadCol(col);
    p.then(fn, e => onErr && onErr(e));
    return () => listeners.get(key).delete(fn);
  }
  function splitPath(path) {
    const i = path.indexOf('/');
    if (i < 1 || path.indexOf('/', i + 1) !== -1) throw err('invalid_argument', 'Bad document path: ' + path);
    return [path.slice(0, i), path.slice(i + 1)];
  }

  async function setDoc(path, data) {
    const [col, id] = splitPath(path);
    if (col === 'team') {
      const { error } = await sb.from('members').update({ role: data.role, name: data.label || null, updated_at: new Date().toISOString() }).eq('user_id', id);
      if (error) throw err('invalid_argument', error.message);
      return fetchMembers();
    }
    if (col === 'requests') {
      const { error } = await sb.rpc('request_access', { p_name: (data && data.label) || '' });
      if (error) throw err('invalid_argument', error.message);
      return fetchMembers();
    }
    const clean = JSON.parse(JSON.stringify(data));
    const { error } = await sb.from('docs').upsert({ col, id, data: clean, updated_at: new Date().toISOString() }, { onConflict: 'col,id' });
    if (error) throw err(/fetch|network/i.test(error.message) ? 'unavailable' : 'invalid_argument', error.message);
    if (docs.has(col)) { docs.get(col).set(id, clean); emit(col); }
  }
  async function deleteDoc(path) {
    const [col, id] = splitPath(path);
    if (col === 'team' || col === 'requests') {
      // Declining a request only applies while the person is still waiting (approving also clears the request).
      let q = sb.from('members').update({ role: 'removed', updated_at: new Date().toISOString() }).eq('user_id', id);
      if (col === 'requests') q = q.eq('role', 'pending');
      const { error } = await q;
      if (error) throw err('invalid_argument', error.message);
      return fetchMembers();
    }
    const { error } = await sb.from('docs').delete().eq('col', col).eq('id', id);
    if (error) throw err('invalid_argument', error.message);
    if (docs.has(col)) { docs.get(col).delete(id); emit(col); }
  }

  const db = Object.freeze({
    collection(col) {
      return {
        onSnapshot(next, onErr) {
          return subscribe(col, () => {
            const m = colMap(col);
            next({ docs: [...m].map(([id, d]) => snapDoc(id, d)), metadata: { fromCache: false } });
          }, onErr);
        }
      };
    },
    doc(path) {
      const [col, id] = splitPath(path);
      return {
        onSnapshot(next, onErr) {
          // A person's own access: team/<me> exists once they have a role; requests/<me> while they wait.
          return subscribe(col, () => next(snapDoc(id, colMap(col).get(id))), onErr);
        },
        set: data => setDoc(path, data),
        delete: () => deleteDoc(path),
        async get() { await (VIRTUAL.includes(col) ? loadMembers() : loadCol(col)); return snapDoc(id, colMap(col).get(id)); }
      };
    }
  });

  const user = Object.freeze({
    isOwner: async () => !!(me && me.role === 'owner'),
    canEdit: async () => !!(me && me.role === 'owner'),
    can: async () => true,
    id: async () => (session ? session.user.id : null),
    me: async () => ({ id: session ? session.user.id : null, name: (me && me.name) || '', email: session ? session.user.email : null, isOwner: !!(me && me.role === 'owner'), canEdit: !!(me && me.role === 'owner'), avatarUrl: '', color: '#EB6123' }),
    async profiles(ids) {
      const out = {};
      for (const id of [].concat(ids)) { const r = members.get(id); out[id] = { id, name: r ? (r.name || r.email || '') : '', email: r ? r.email : null, avatarUrl: '', color: '#EB6123', isMe: !!(session && id === session.user.id), guest: false }; }
      return out;
    }
  });

  const downloads = Object.freeze({
    async save({ filename, data }) {
      const blob = data instanceof Blob ? data : new Blob([data]);
      if (desktop && desktop.saveFile) {
        const bytes = new Uint8Array(await blob.arrayBuffer());
        const where = await desktop.saveFile(filename, bytes);
        return { status: 'saved', path: where };
      }
      const a = document.createElement('a');
      a.href = URL.createObjectURL(blob); a.download = filename;
      document.body.append(a); a.click(); a.remove();
      setTimeout(() => URL.revokeObjectURL(a.href), 30000);
      return { status: 'saved' };
    }
  });

  // Owner tools for Team & access (the database refuses them for anyone else).
  const rpcErr = error => { throw err('invalid_argument', String(error.message || error).replace(/^.*?exception:?\s*/i, '')); };
  window.firstboxTeam = Object.freeze({
    async create(username, password, name, role) {
      const { error } = await sb.rpc('create_member', { p_username: username, p_password: password, p_name: name, p_role: role });
      if (error) rpcErr(error);
      await fetchMembers();
    },
    async setPassword(userId, password) {
      const { error } = await sb.rpc('set_member_password', { p_user: userId, p_password: password });
      if (error) rpcErr(error);
    },
    async remove(userId) {
      const { error } = await sb.rpc('delete_member', { p_user: userId });
      if (error) rpcErr(error);
      await fetchMembers();
    }
  });

  // Client details from a GSTIN, through the database (the service key never reaches the browser). See supabase/gst-lookup.sql.
  window.firstboxGst = Object.freeze({
    async lookup(gstin) {
      const { data, error } = await sb.rpc('gst_lookup', { p_gstin: gstin });
      if (error) rpcErr(error);
      return data;
    },
    async setKey(key) {
      const { error } = await sb.rpc('set_gst_api_key', { p_key: key });
      if (error) rpcErr(error);
    },
    async isSet() {
      const { data, error } = await sb.rpc('gst_key_set');
      if (error) return false;
      return !!data;
    }
  });

  window.claude = Object.freeze({
    async use(name) {
      if (!['db', 'user', 'downloads'].includes(name)) return null;
      await ready;
      return name === 'db' ? db : name === 'user' ? user : downloads;
    }
  });

  // ---------- start ----------
  async function signedIn(s) {
    session = s;
    try {
      const { data, error } = await sb.from('members').select('user_id,email,name,role,created_at,username').eq('user_id', s.user.id).maybeSingle();
      if (error) throw error;
      if (!data) { showAuth('signin', { text: 'Your account is not set up in the database yet. Ask the owner to check the Supabase setup.', bad: true }); return; }
      me = data; members.set(data.user_id, data);
    } catch (e) {
      showAuth('signin', { text: 'Couldn’t reach the Firstbox database. Check your internet connection and try again.', bad: true });
      return;
    }
    hideAuth(); addSignOut(); startRealtime();
    resolveReady();
  }
  function start() {
    css();
    if (!window.supabase || !cfg.url || !cfg.key) {
      showAuth('signin', { text: 'This copy of the app is missing its database settings (config.js).', bad: true });
      return;
    }
    sb = window.supabase.createClient(cfg.url, cfg.key, { auth: { persistSession: true, autoRefreshToken: true, storageKey: 'firstbox-auth' } });
    let started = false;
    sb.auth.onAuthStateChange((event, s) => {
      if (s && !started) { started = true; signedIn(s); }
      else if (!s && event === 'SIGNED_OUT') location.reload();
      else if (s) session = s;
    });
    sb.auth.getSession().then(({ data }) => {
      if (data.session) { if (!started) { started = true; signedIn(data.session); } }
      else showAuth('signin', navigator.onLine ? null : { text: 'No internet connection. Connect to sign in.', bad: true });
    });
  }
  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', start); else start();
})();
