#!/usr/bin/env node
// App list server for Personal Obtainium.
//
// Each device category has its own list, named by a short id such as 1, 2 or car.
//
// Lists:     GET /apps/<id>?key=K  -> {"apps": [...]} read by the app on open
//            GET /<id>             -> same as /apps/<id>
//            GET /apps/<id>.txt    -> one link per line
//            GET /apps.json        -> the first list (for older links)
//            GET /health           -> "ok" (no key needed)
//            When LIST_KEY is set, every list URL needs ?key=LIST_KEY (a short code that is
//            easy to type on a car screen). When APP_KEY is set, the request must also carry
//            the X-App-Key header that is built into the APK. Otherwise the server answers
//            404, as if the list did not exist. Too many wrong tries block that IP for an hour.
// Protected: GET /dashboard        -> web page to manage lists and links
//            /api/lists...         -> JSON API behind the dashboard
//
// Requests are rate limited per client IP, and repeated wrong dashboard passwords lock that
// IP out for a while. Behind a local reverse proxy (Caddy), the client IP is taken from
// X-Forwarded-For.
//
// No dependencies. Needs Node 18 or newer.

'use strict';

const http = require('http');
const fs = require('fs');
const path = require('path');
const crypto = require('crypto');

const PORT = parseInt(process.env.PORT || '8080', 10);
const HOST = process.env.HOST || '0.0.0.0';
const DATA_FILE = process.env.DATA_FILE || path.join(__dirname, 'data', 'lists.json');
const SEED_FILE = path.join(__dirname, 'apps.seed.json');
const DASHBOARD_USER = process.env.DASHBOARD_USER || 'admin';
const DASHBOARD_PASSWORD = process.env.DASHBOARD_PASSWORD || '';
const DASHBOARD_HTML = path.join(__dirname, 'public', 'dashboard.html');
const LIST_KEY = process.env.LIST_KEY || '';
const APP_KEY = process.env.APP_KEY || '';
const KEY_FAILS = parseInt(process.env.KEY_FAILS || '20', 10);
const MAX_BODY = 64 * 1024;
// Per client IP: requests per minute, and wrong dashboard logins per 15 minutes.
const RATE_PER_MIN = parseInt(process.env.RATE_PER_MIN || '60', 10);
const LOGIN_FAILS = parseInt(process.env.LOGIN_FAILS || '10', 10);
const ID_RE = /^[a-z0-9][a-z0-9_-]{0,31}$/;
const RESERVED = new Set(['apps', 'api', 'dashboard', 'health']);

if (!DASHBOARD_PASSWORD) {
  console.error('DASHBOARD_PASSWORD is not set. Refusing to start with an open dashboard.');
  process.exit(1);
}

// ---------- validation ----------

function normalizeUrl(raw) {
  if (typeof raw !== 'string') return null;
  let s = raw.trim();
  if (!s) return null;
  if (!/^https?:\/\//i.test(s)) s = 'https://' + s;
  let u;
  try {
    u = new URL(s);
  } catch {
    return null;
  }
  if (u.protocol !== 'https:' && u.protocol !== 'http:') return null;
  if (!u.hostname.includes('.')) return null;
  u.hash = '';
  let out = u.toString();
  // Tidy GitHub repo links: drop trailing slash, ".git", and sub-pages like /releases.
  const gh = out.match(/^https?:\/\/(www\.)?github\.com\/([^/]+)\/([^/?#]+)/i);
  if (gh) {
    out = `https://github.com/${gh[2]}/${gh[3].replace(/\.git$/i, '')}`;
  } else {
    out = out.replace(/\/+$/, '');
  }
  return out;
}

function cleanEntry(item) {
  const url = normalizeUrl(typeof item === 'string' ? item : item && item.url);
  if (!url) return null;
  const entry = { url };
  if (item && typeof item === 'object') {
    if (item.settings && typeof item.settings === 'object' && !Array.isArray(item.settings)) {
      if (Object.keys(item.settings).length) entry.settings = item.settings;
    }
    if (typeof item.note === 'string' && item.note.trim()) entry.note = item.note.trim().slice(0, 200);
  }
  return entry;
}

function cleanApps(list) {
  const seen = new Set();
  const out = [];
  for (const item of Array.isArray(list) ? list : []) {
    const e = cleanEntry(item);
    if (e && !seen.has(e.url.toLowerCase())) {
      seen.add(e.url.toLowerCase());
      out.push(e);
    }
  }
  return out;
}

function cleanId(raw) {
  const id = String(raw == null ? '' : raw).trim().toLowerCase();
  return ID_RE.test(id) && !RESERVED.has(id) ? id : null;
}

function cleanName(raw, fallback) {
  const name = typeof raw === 'string' ? raw.trim().slice(0, 60) : '';
  return name || fallback;
}

// ---------- storage ----------

// lists: [{ id, name, apps: [{url, note?, settings?}] }], in display order.
let lists = load();
if (!fs.existsSync(DATA_FILE)) save();

function load() {
  if (fs.existsSync(DATA_FILE)) return fromJson(JSON.parse(fs.readFileSync(DATA_FILE, 'utf8')));
  // Data from the first version of this server: a single {"apps": [...]} file.
  const old = path.join(path.dirname(DATA_FILE), 'apps.json');
  if (fs.existsSync(old)) return fromJson(JSON.parse(fs.readFileSync(old, 'utf8')));
  return fromJson(JSON.parse(fs.readFileSync(SEED_FILE, 'utf8')));
}

function fromJson(parsed) {
  if (Array.isArray(parsed) || Array.isArray(parsed.apps)) {
    return [{ id: '1', name: 'List 1', apps: cleanApps(Array.isArray(parsed) ? parsed : parsed.apps) }];
  }
  const out = [];
  for (const l of parsed.lists || []) {
    const id = cleanId(l.id);
    if (id && !out.some((x) => x.id === id)) out.push({ id, name: cleanName(l.name, id), apps: cleanApps(l.apps) });
  }
  return out;
}

function save() {
  fs.mkdirSync(path.dirname(DATA_FILE), { recursive: true });
  const tmp = DATA_FILE + '.tmp';
  fs.writeFileSync(tmp, JSON.stringify({ lists }, null, 2) + '\n');
  fs.renameSync(tmp, DATA_FILE);
}

function findList(id) {
  return lists.find((l) => l.id === String(id).toLowerCase());
}

// The app only needs url and settings; the note is for the dashboard.
function publicApps(list) {
  return list.apps.map((a) => (a.settings ? { url: a.url, settings: a.settings } : a.url));
}

// ---------- http helpers ----------

function send(res, status, body, type = 'application/json; charset=utf-8', extra = {}) {
  const data = typeof body === 'string' || Buffer.isBuffer(body) ? body : JSON.stringify(body);
  res.writeHead(status, { 'Content-Type': type, 'Cache-Control': 'no-store', ...extra });
  res.end(data);
}

function safeEqual(a, b) {
  const ha = crypto.createHash('sha256').update(a).digest();
  const hb = crypto.createHash('sha256').update(b).digest();
  return crypto.timingSafeEqual(ha, hb);
}

function authorized(req) {
  const h = req.headers.authorization || '';
  if (!h.startsWith('Basic ')) return false;
  const decoded = Buffer.from(h.slice(6), 'base64').toString('utf8');
  const i = decoded.indexOf(':');
  if (i < 0) return false;
  const userOk = safeEqual(decoded.slice(0, i), DASHBOARD_USER);
  const passOk = safeEqual(decoded.slice(i + 1), DASHBOARD_PASSWORD);
  return userOk && passOk;
}

function challenge(res) {
  send(res, 401, { error: 'Login required' }, 'application/json; charset=utf-8', {
    'WWW-Authenticate': 'Basic realm="App list dashboard", charset="UTF-8"',
  });
}

function readJson(req) {
  return new Promise((resolve, reject) => {
    let size = 0;
    const chunks = [];
    req.on('data', (c) => {
      size += c.length;
      if (size > MAX_BODY) {
        reject(new Error('Body too large'));
        req.destroy();
      } else chunks.push(c);
    });
    req.on('end', () => {
      try {
        resolve(chunks.length ? JSON.parse(Buffer.concat(chunks).toString('utf8')) : {});
      } catch {
        reject(new Error('Invalid JSON'));
      }
    });
    req.on('error', reject);
  });
}

// ---------- abuse limits ----------

const hits = new Map(); // ip -> { n, reset }
const fails = new Map(); // ip -> { n, reset }
const keyFails = new Map(); // ip -> { n, reset }

function clientIp(req) {
  const peer = req.socket.remoteAddress || '';
  const local = peer === '127.0.0.1' || peer === '::1' || peer === '::ffff:127.0.0.1';
  const xff = req.headers['x-forwarded-for'];
  if (local && typeof xff === 'string' && xff) return xff.split(',').pop().trim();
  return peer;
}

// Counts one event for ip in map; returns false once more than max happened in the window.
function count(map, ip, max, windowMs) {
  const now = Date.now();
  let e = map.get(ip);
  if (!e || e.reset <= now) {
    if (map.size > 50000) map.clear(); // a flood of distinct IPs must not exhaust memory
    e = { n: 0, reset: now + windowMs };
    map.set(ip, e);
  }
  e.n++;
  return e.n <= max;
}

function lockedOut(ip, map = fails, max = LOGIN_FAILS) {
  const e = map.get(ip);
  return !!e && e.reset > Date.now() && e.n >= max;
}

setInterval(() => {
  const now = Date.now();
  for (const map of [hits, fails, keyFails]) for (const [ip, e] of map) if (e.reset <= now) map.delete(ip);
}, 60 * 1000).unref();

function hasKeys(req, url) {
  const k = url.searchParams.get('key') || '';
  const a = req.headers['x-app-key'] || '';
  const listOk = !LIST_KEY || (k !== '' && safeEqual(k, LIST_KEY));
  const appOk = !APP_KEY || (typeof a === 'string' && a !== '' && safeEqual(a, APP_KEY));
  return listOk && appOk;
}

// ---------- routes ----------

function sendList(res, list, asText) {
  if (asText) return send(res, 200, list.apps.map((a) => a.url).join('\n') + '\n', 'text/plain; charset=utf-8');
  send(res, 200, { apps: publicApps(list) }, 'application/json; charset=utf-8', {
    'Access-Control-Allow-Origin': '*',
  });
}

function ok(res, status = 200) {
  send(res, status, { lists, listKey: LIST_KEY || null, appKeyRequired: !!APP_KEY });
}

async function handleApi(req, res, p) {
  // Requiring a JSON content type on writes blocks cross-site form posts.
  if (req.method !== 'GET' && !(req.headers['content-type'] || '').includes('application/json')) {
    return send(res, 415, { error: 'Use Content-Type: application/json' });
  }
  const parts = p.split('/').slice(3).map(decodeURIComponent); // after /api/lists
  const body = req.method === 'GET' ? {} : await readJson(req);

  // /api/lists
  if (parts.length === 0) {
    if (req.method === 'GET') return ok(res);
    if (req.method === 'POST') {
      const id = cleanId(body.id);
      if (!id) {
        return send(res, 400, {
          error: 'Use a short id: lowercase letters, digits, - or _, up to 32 characters (for example 2 or car)',
        });
      }
      if (findList(id)) return send(res, 409, { error: `List ${id} already exists` });
      lists.push({ id, name: cleanName(body.name, `List ${id}`), apps: [] });
      save();
      return ok(res, 201);
    }
    if (req.method === 'PUT') {
      // Reorder lists: {"order": ["1", "car", ...]}
      if (!Array.isArray(body.order)) return send(res, 400, { error: 'Expected {"order": [...]}' });
      const rank = new Map(body.order.map((id, i) => [String(id), i]));
      lists.sort((a, b) => (rank.get(a.id) ?? 1e9) - (rank.get(b.id) ?? 1e9));
      save();
      return ok(res);
    }
    return send(res, 405, { error: 'Method not allowed' });
  }

  const list = findList(parts[0]);
  if (!list) return send(res, 404, { error: 'List not found' });

  // /api/lists/<id>
  if (parts.length === 1) {
    if (req.method === 'PATCH') {
      list.name = cleanName(body.name, list.name);
      save();
      return ok(res);
    }
    if (req.method === 'DELETE') {
      lists = lists.filter((l) => l !== list);
      save();
      return ok(res);
    }
    return send(res, 405, { error: 'Method not allowed' });
  }

  // /api/lists/<id>/apps
  if (parts.length === 2 && parts[1] === 'apps') {
    if (req.method === 'POST') {
      const entry = cleanEntry(body);
      if (!entry) return send(res, 400, { error: 'That is not a valid http(s) link' });
      if (list.apps.some((a) => a.url.toLowerCase() === entry.url.toLowerCase())) {
        return send(res, 409, { error: 'That link is already in this list' });
      }
      list.apps.push(entry);
      save();
      return ok(res, 201);
    }
    if (req.method === 'DELETE') {
      const target = (normalizeUrl(body.url || '') || '').toLowerCase();
      const before = list.apps.length;
      list.apps = list.apps.filter((a) => a.url.toLowerCase() !== target);
      if (list.apps.length === before) return send(res, 404, { error: 'Link not found' });
      save();
      return ok(res);
    }
    if (req.method === 'PUT') {
      // Replace the whole list (used for reordering).
      if (!Array.isArray(body.apps)) return send(res, 400, { error: 'Expected {"apps": [...]}' });
      for (const item of body.apps) {
        if (!cleanEntry(item)) return send(res, 400, { error: `Invalid link: ${JSON.stringify(item).slice(0, 100)}` });
      }
      list.apps = cleanApps(body.apps);
      save();
      return ok(res);
    }
  }
  send(res, 405, { error: 'Method not allowed' });
}

const server = http.createServer(async (req, res) => {
  const ip = clientIp(req);
  if (!count(hits, ip, RATE_PER_MIN, 60 * 1000)) {
    return send(res, 429, { error: 'Too many requests' }, 'application/json; charset=utf-8', {
      'Retry-After': '60',
      Connection: 'close',
    });
  }
  const url = new URL(req.url, 'http://localhost');
  const p = url.pathname.replace(/\/+$/, '') || '/';
  try {
    if (req.method === 'GET') {
      if (p === '/health') return send(res, 200, 'ok', 'text/plain');
    }
    if (req.method === 'GET' && (p === '/favicon.ico' || p === '/robots.txt')) {
      return send(res, 404, { error: 'Not found' });
    }
    if (req.method === 'GET' && p !== '/' && p !== '/dashboard' && !p.startsWith('/api/')) {
      if (lockedOut(ip, keyFails, KEY_FAILS)) return send(res, 404, { error: 'Not found' });
      if (!hasKeys(req, url)) {
        count(keyFails, ip, KEY_FAILS, 60 * 60 * 1000);
        return send(res, 404, { error: 'Not found' });
      }
    }
    if (req.method === 'GET') {
      if (p === '/') {
        res.writeHead(302, { Location: '/dashboard' });
        return res.end();
      }
      if (p === '/apps.json' || p === '/apps' || p === '/apps.txt') {
        if (!lists.length) return send(res, 404, { error: 'No lists yet' });
        return sendList(res, lists[0], p.endsWith('.txt'));
      }
      // /apps/<id>, /apps/<id>.json, /apps/<id>.txt, /<id>
      const m = p.match(/^(?:\/apps)?\/([^/]+?)(\.json|\.txt)?$/);
      if (m && !RESERVED.has(m[1].toLowerCase())) {
        const list = findList(decodeURIComponent(m[1]));
        if (list) return sendList(res, list, m[2] === '.txt');
      }
    }
    if (p === '/dashboard' || p === '/api/lists' || p.startsWith('/api/')) {
      if (lockedOut(ip)) {
        return send(res, 429, { error: 'Too many wrong passwords. Try again later.' }, 'application/json; charset=utf-8', {
          'Retry-After': '900',
        });
      }
      if (!authorized(req)) {
        if (req.headers.authorization) count(fails, ip, LOGIN_FAILS, 15 * 60 * 1000);
        return challenge(res);
      }
      if (p === '/dashboard' && req.method === 'GET') {
        return send(res, 200, fs.readFileSync(DASHBOARD_HTML), 'text/html; charset=utf-8', {
          'X-Frame-Options': 'DENY',
          'Content-Security-Policy':
            "default-src 'self'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; connect-src 'self' https://api.github.com; img-src 'self' data:",
        });
      }
      if (p === '/api/lists' || p.startsWith('/api/lists/')) return await handleApi(req, res, p);
    }
    send(res, 404, { error: 'Not found' });
  } catch (err) {
    send(res, 400, { error: err.message || 'Bad request' });
  }
});

// Drop slow or oversized requests quickly so idle connections cannot pile up.
server.headersTimeout = 10 * 1000;
server.requestTimeout = 15 * 1000;
server.keepAliveTimeout = 5 * 1000;
server.maxHeadersCount = 50;
server.maxRequestsPerSocket = 100;

server.listen(PORT, HOST, () => {
  console.log(`App list server on http://${HOST}:${PORT}  (lists: /apps/<id>, dashboard: /dashboard)`);
  if (!APP_KEY) console.warn('APP_KEY is not set: list requests are not tied to the app.');
  if (!LIST_KEY) console.warn('LIST_KEY is not set: anyone who knows a list id can read that list.');
  console.log(`Data file: ${DATA_FILE}  (${lists.map((l) => `${l.id}: ${l.apps.length} links`).join(', ') || 'no lists'})`);
});
