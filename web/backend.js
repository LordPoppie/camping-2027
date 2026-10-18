// Opslag en inloggen. Met Supabase als config.js is ingevuld, anders demo-modus in localStorage.
// Biedt dezelfde kleine db/user-interface die de pagina gebruikt: doc(path).get/set en collection(name).onSnapshot.
import { SUPABASE_URL, SUPABASE_KEY } from "./config.js";
import { createClient } from "https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2.45.4/+esm";

export const DEMO = !(SUPABASE_URL && SUPABASE_KEY);
export const sb = DEMO ? null : createClient(SUPABASE_URL, SUPABASE_KEY);

const must = ({ data, error }) => { if (error) throw error; return data; };
const snap = rows => ({ docs: rows.map(([id, data]) => ({ id, exists: true, data: () => data })) });

// ───────────── inloggen ─────────────

export const auth = DEMO ? {
  async session() { try { const e = localStorage.getItem("gb-demo-email"); return e ? { user: { id: "demo", email: e } } : null; } catch (e) { return null; } },
  onAuth() {},
  async signIn(email) { try { localStorage.setItem("gb-demo-email", email); } catch (e) {} return { demo: true }; },
  async verifyCode() { return {}; },
  async signOut() { try { localStorage.removeItem("gb-demo-email"); } catch (e) {} },
} : {
  async session() { return (await sb.auth.getSession()).data.session; },
  onAuth(cb) { sb.auth.onAuthStateChange((_e, s) => cb(s)); },
  signIn(email) { return sb.auth.signInWithOtp({ email, options: { emailRedirectTo: location.origin + location.pathname } }); },
  verifyCode(email, token) { return sb.auth.verifyOtp({ email, token, type: "email" }); },
  signOut() { return sb.auth.signOut(); },
};

// ───────────── tabellen ─────────────

const TABLES = {
  responses: {
    table: "camping_responses",
    async all() { return must(await sb.from("camping_responses").select("user_id,data")).map(r => [r.user_id, r.data]); },
    async get(id) { const r = must(await sb.from("camping_responses").select("data").eq("user_id", id).maybeSingle()); return r && r.data; },
    async set(id, body) { must(await sb.from("camping_responses").upsert({ user_id: id, data: body })); },
  },
  guests: {
    table: "camping_guests",
    async all() { return must(await sb.from("camping_guests").select("user_id,names,going,updated_at")).map(r => [r.user_id, { names: r.names, going: r.going, updatedAt: r.updated_at }]); },
    async get(id) { const r = must(await sb.from("camping_guests").select("names,going,updated_at").eq("user_id", id).maybeSingle()); return r && { names: r.names, going: r.going, updatedAt: r.updated_at }; },
    async set(id, body) { must(await sb.from("camping_guests").upsert({ user_id: id, names: body.names, going: body.going })); },
  },
  // e-mailadressen komen uit het account zelf (trigger op auth.users)
  contacts: {
    table: "camping_profiles",
    async all() { return must(await sb.from("camping_profiles").select("user_id,email")).map(r => [r.user_id, { email: r.email }]); },
    async get(id) { const r = must(await sb.from("camping_profiles").select("email").eq("user_id", id).maybeSingle()); return r && { email: r.email }; },
    async set() {},
  },
};

function supabaseDb() {
  return {
    doc(path) {
      const [name, id] = path.split("/");
      const t = TABLES[name];
      return {
        async get() { const d = await t.get(id); return { id, exists: !!d, data: () => d || undefined }; },
        async set(body) { await t.set(id, body); },
      };
    },
    collection(name) {
      const t = TABLES[name];
      return {
        onSnapshot(next, onError) {
          let stopped = false, timer = null;
          const load = async () => {
            try { const rows = await t.all(); if (!stopped) next(snap(rows)); }
            catch (e) { if (!stopped && onError) onError({ code: "unavailable", message: e.message }); }
          };
          const later = () => { clearTimeout(timer); timer = setTimeout(load, 250); };
          const ch = sb.channel("live-" + name + "-" + Math.random().toString(36).slice(2))
            .on("postgres_changes", { event: "*", schema: "public", table: t.table || name }, later)
            .subscribe();
          const poll = setInterval(load, 30000);
          load();
          return () => { stopped = true; clearInterval(poll); clearTimeout(timer); sb.removeChannel(ch); };
        },
      };
    },
  };
}

// demo: alles in localStorage, jij bent de organisatie
function demoDb() {
  const KEY = "gb-demo-db";
  const read = () => { try { return JSON.parse(localStorage.getItem(KEY) || "{}"); } catch (e) { return {}; } };
  const write = s => { try { localStorage.setItem(KEY, JSON.stringify(s)); } catch (e) {} };
  const listeners = {};
  const emit = name => (listeners[name] || []).forEach(fn => fn());
  return {
    doc(path) {
      const [name, id] = path.split("/");
      return {
        async get() { const d = (read()[name] || {})[id]; return { id, exists: !!d, data: () => d }; },
        async set(body) { const s = read(); (s[name] ||= {})[id] = body; write(s); emit(name); },
      };
    },
    collection(name) {
      return {
        onSnapshot(next) {
          const fire = () => next(snap(Object.entries(read()[name] || {})));
          (listeners[name] ||= []).push(fire);
          setTimeout(fire, 0);
          return () => { listeners[name] = listeners[name].filter(f => f !== fire); };
        },
      };
    },
  };
}

export const db = DEMO ? demoDb() : supabaseDb();

export function makeUser(session) {
  const id = session && session.user ? session.user.id : null;
  const email = session && session.user ? session.user.email : null;
  let owner = null;
  return {
    async id() { return id; },
    async email() { return email; },
    async isOwner() {
      if (DEMO) return true;
      if (owner === null) { try { owner = !!must(await sb.rpc("camping_is_organizer")); } catch (e) { owner = false; } }
      return owner;
    },
    async can() { return null; },
    async me() { return { id, name: "", email, avatarUrl: "", color: "", isOwner: await this.isOwner(), canEdit: false }; },
    async profiles() { return {}; },
  };
}
