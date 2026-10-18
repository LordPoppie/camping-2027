// Opslag en inloggen. Met Supabase als config.js is ingevuld, anders demo-modus in localStorage.
// Vrienden checken in met naam + kampcode (4 cijfers); de organisatie logt daarnaast in met e-mail
// voor het volledige overzicht. Biedt de kleine db/user-interface die de pagina gebruikt.
import { SUPABASE_URL, SUPABASE_KEY } from "./config.js";
import { createClient } from "https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2.45.4/+esm";

export const DEMO = !(SUPABASE_URL && SUPABASE_KEY);
export const sb = DEMO ? null : createClient(SUPABASE_URL, SUPABASE_KEY);

const TOKEN_KEY = "gb-kamp-token";
const store = {
  get(k) { try { return localStorage.getItem(k); } catch (e) { return null; } },
  set(k, v) { try { localStorage.setItem(k, v); } catch (e) {} },
  del(k) { try { localStorage.removeItem(k); } catch (e) {} },
};
const must = ({ data, error }) => { if (error) throw error; return data; };
const rpc = async (fn, args) => must(await sb.rpc(fn, args));
const snap = rows => ({ docs: rows.map(([id, data]) => ({ id, exists: true, data: () => data })) });

// ───────────── demo-opslag ─────────────

const DEMO_KEY = "gb-demo-db";
const demoRead = () => { try { return JSON.parse(localStorage.getItem(DEMO_KEY) || "{}"); } catch (e) { return {}; } };
const demoWrite = s => store.set(DEMO_KEY, JSON.stringify(s));

// ───────────── inchecken met naam + kampcode ─────────────
// login() geeft { status: "ok" | "unknown" | "wrong_pin" | "locked" | "bad_pin" | "bad_name", member }

export const kamp = DEMO ? {
  async login(name, pin, create) {
    const s = demoRead(); s.members ||= {};
    const key = name.trim().toLowerCase();
    let m = s.members[key];
    if (!m) {
      if (!create) return { status: "unknown" };
      m = s.members[key] = { member_id: "demo-" + Math.random().toString(36).slice(2, 10), name: name.trim(), pin };
      demoWrite(s);
    } else if (m.pin !== pin) return { status: "wrong_pin" };
    store.set(TOKEN_KEY, m.member_id);
    return { status: "ok", member: { member_id: m.member_id, name: m.name } };
  },
  async me() {
    const t = store.get(TOKEN_KEY); if (!t) return null;
    const m = Object.values(demoRead().members || {}).find(m => m.member_id === t);
    return m ? { member_id: m.member_id, name: m.name } : null;
  },
  async logout() { store.del(TOKEN_KEY); },
} : {
  async login(name, pin, create) {
    const r = await rpc("camping_login", { p_name: name, p_pin: pin, p_create: !!create });
    if (r.status === "ok") { store.set(TOKEN_KEY, r.token); return { status: "ok", member: { member_id: r.member_id, name: r.name } }; }
    return { status: r.status };
  },
  async me() {
    const t = store.get(TOKEN_KEY); if (!t) return null;
    try { const r = await rpc("camping_me", { p_token: t }); if (!r) store.del(TOKEN_KEY); return r; }
    catch (e) { return null; }
  },
  async logout() {
    const t = store.get(TOKEN_KEY);
    store.del(TOKEN_KEY);
    if (t) { try { await rpc("camping_logout", { p_token: t }); } catch (e) {} }
  },
};

// ───────────── e-maillogin voor de organisatie ─────────────

export const orgAuth = DEMO ? {
  async session() { return null; },
  onAuth() {},
  async signIn() { return { demo: true }; },
  async signOut() {},
} : {
  async session() { return (await sb.auth.getSession()).data.session; },
  onAuth(cb) { sb.auth.onAuthStateChange((e, s) => cb(e, s)); },
  signIn(email) { return sb.auth.signInWithOtp({ email, options: { emailRedirectTo: location.origin + location.pathname, shouldCreateUser: false } }); },
  signOut() { return sb.auth.signOut(); },
};

async function isOrganizer() {
  if (DEMO) return true;
  if (!(await orgAuth.session())) return false;
  try { return !!(await rpc("camping_is_organizer")); } catch (e) { return false; }
}

// ───────────── db-interface voor de pagina ─────────────

const listeners = new Set();
const refreshAll = () => listeners.forEach(fn => fn());

function poller(load, next, onError) {
  let stopped = false;
  const run = async () => {
    try { const rows = await load(); if (!stopped) next(snap(rows)); }
    catch (e) { if (!stopped && onError) onError({ code: "unavailable", message: e.message }); }
  };
  listeners.add(run);
  const iv = setInterval(run, 20000);
  run();
  return () => { stopped = true; clearInterval(iv); listeners.delete(run); };
}

function supabaseDb() {
  const token = () => store.get(TOKEN_KEY);
  return {
    doc(path) {
      const [name] = path.split("/");
      return {
        async get() {
          if (name !== "responses") return { exists: false, data: () => undefined };
          const r = await rpc("camping_me", { p_token: token() });
          return { exists: !!(r && r.data), data: () => (r && r.data) || undefined };
        },
        async set(body) {
          if (name !== "responses") return; // namen en ja/nee gaan mee met de kaart
          const names = (body.people || []).map(p => p.n).filter(Boolean);
          const r = await rpc("camping_save", { p_token: token(), p_data: body, p_names: names, p_going: body.going || null });
          if (!r || r.status !== "ok") throw { code: "invalid_argument", message: "Niet ingecheckt" };
          refreshAll();
        },
      };
    },
    collection(name) {
      return {
        onSnapshot(next, onError) {
          if (name === "guests") return poller(async () => (await rpc("camping_guest_list", { p_token: token() }))
            .map(r => [r.member_id, { names: r.names, going: r.going, updatedAt: r.updated_at }]), next, onError);
          if (name === "responses") return poller(async () => (await rpc("camping_admin_responses"))
            .map(r => [r.member_id, r.data]), next, onError);
          setTimeout(() => next(snap([])), 0);
          return () => {};
        },
      };
    },
  };
}

function demoDb() {
  const coll = name => ({ guests: "guests", responses: "responses" }[name]);
  return {
    doc(path) {
      const [name, id] = path.split("/");
      return {
        async get() { const d = ((demoRead()[coll(name)] || {})[id]); return { exists: !!d, data: () => d }; },
        async set(body) { const s = demoRead(); (s[coll(name)] ||= {})[id] = body; demoWrite(s); refreshAll(); },
      };
    },
    collection(name) {
      return {
        onSnapshot(next) {
          return poller(async () => coll(name) ? Object.entries(demoRead()[coll(name)] || {}) : [], next);
        },
      };
    },
  };
}

export const db = DEMO ? demoDb() : supabaseDb();

export function makeUser(member) {
  let owner = null;
  return {
    async id() { return member.member_id; },
    async isOwner() { if (owner === null) owner = await isOrganizer(); return owner; },
    async can() { return null; },
    async me() { return { id: member.member_id, name: member.name }; },
    async profiles() { return {}; },
  };
}
