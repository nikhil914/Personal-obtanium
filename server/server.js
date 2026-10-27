#!/usr/bin/env node
// App list server for Personal Obtainium.
//
// Public:    GET /apps.json        -> {"apps": [...]} read by the app on open
//            GET /apps.txt         -> one link per line
//            GET /health           -> "ok"
// Protected: GET /dashboard        -> web page to add, remove and reorder links
//            GET/POST/DELETE/PUT /api/apps
//
// No dependencies. Needs Node 18 or newer.

'use strict';

const http = require('http');
const fs = require('fs');
const path = require('path');
const crypto = require('crypto');

const PORT = parseInt(process.env.PORT || '8080', 10);
const HOST = process.env.HOST || '0.0.0.0';
const DATA_FILE = process.env.DATA_FILE || path.join(__dirname, 'data', 'apps.json');
const SEED_FILE = path.join(__dirname, 'apps.seed.json');
const DASHBOARD_USER = process.env.DASHBOARD_USER || 'admin';
const DASHBOARD_PASSWORD = process.env.DASHBOARD_PASSWORD || '';
const DASHBOARD_HTML = path.join(__dirname, 'public', 'dashboard.html');
const MAX_BODY = 64 * 1024;

if (!DASHBOARD_PASSWORD) {
  console.error('DASHBOARD_PASSWORD is not set. Refusing to start with an open dashboard.');
  process.exit(1);
}

// ---------- storage ----------

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

function loadApps() {
  const file = fs.existsSync(DATA_FILE) ? DATA_FILE : SEED_FILE;
  const parsed = JSON.parse(fs.readFileSync(file, 'utf8'));
  const list = Array.isArray(parsed) ? parsed : parsed.apps || [];
  const seen = new Set();
  const apps = [];
  for (const item of list) {
    const e = cleanEntry(item);
    if (e && !seen.has(e.url.toLowerCase())) {
      seen.add(e.url.toLowerCase());
      apps.push(e);
    }
  }
  return apps;
}

let apps = loadApps();
if (!fs.existsSync(DATA_FILE)) saveApps();

function saveApps() {
  fs.mkdirSync(path.dirname(DATA_FILE), { recursive: true });
  const tmp = DATA_FILE + '.tmp';
  fs.writeFileSync(tmp, JSON.stringify({ apps }, null, 2) + '\n');
  fs.renameSync(tmp, DATA_FILE);
}

// The app only needs url and settings; the note is for the dashboard.
function publicList() {
  return apps.map((a) => (a.settings ? { url: a.url, settings: a.settings } : a.url));
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

// ---------- routes ----------

async function handleApi(req, res, url) {
  // Requiring a JSON content type on writes blocks cross-site form posts.
  if (req.method !== 'GET' && !(req.headers['content-type'] || '').includes('application/json')) {
    return send(res, 415, { error: 'Use Content-Type: application/json' });
  }

  if (req.method === 'GET') return send(res, 200, { apps });

  const body = await readJson(req);

  if (req.method === 'POST') {
    const entry = cleanEntry(body);
    if (!entry) return send(res, 400, { error: 'That is not a valid http(s) link' });
    if (apps.some((a) => a.url.toLowerCase() === entry.url.toLowerCase())) {
      return send(res, 409, { error: 'That link is already in the list' });
    }
    apps.push(entry);
    saveApps();
    return send(res, 201, { apps });
  }

  if (req.method === 'DELETE') {
    const target = normalizeUrl(body.url || url.searchParams.get('url') || '');
    const before = apps.length;
    apps = apps.filter((a) => a.url.toLowerCase() !== (target || '').toLowerCase());
    if (apps.length === before) return send(res, 404, { error: 'Link not found' });
    saveApps();
    return send(res, 200, { apps });
  }

  if (req.method === 'PUT') {
    // Replace the whole list (used for reordering and editing notes).
    if (!Array.isArray(body.apps)) return send(res, 400, { error: 'Expected {"apps": [...]}' });
    const seen = new Set();
    const next = [];
    for (const item of body.apps) {
      const e = cleanEntry(item);
      if (!e) return send(res, 400, { error: `Invalid link: ${JSON.stringify(item).slice(0, 100)}` });
      if (!seen.has(e.url.toLowerCase())) {
        seen.add(e.url.toLowerCase());
        next.push(e);
      }
    }
    apps = next;
    saveApps();
    return send(res, 200, { apps });
  }

  send(res, 405, { error: 'Method not allowed' });
}

const server = http.createServer(async (req, res) => {
  const url = new URL(req.url, 'http://localhost');
  const p = url.pathname.replace(/\/+$/, '') || '/';
  try {
    if (req.method === 'GET' && (p === '/apps.json' || p === '/apps')) {
      return send(res, 200, { apps: publicList() }, 'application/json; charset=utf-8', {
        'Access-Control-Allow-Origin': '*',
      });
    }
    if (req.method === 'GET' && p === '/apps.txt') {
      return send(res, 200, apps.map((a) => a.url).join('\n') + '\n', 'text/plain; charset=utf-8');
    }
    if (req.method === 'GET' && p === '/health') return send(res, 200, 'ok', 'text/plain');
    if (req.method === 'GET' && p === '/') {
      res.writeHead(302, { Location: '/dashboard' });
      return res.end();
    }
    if (p === '/dashboard' || p.startsWith('/api/')) {
      if (!authorized(req)) return challenge(res);
      if (p === '/dashboard' && req.method === 'GET') {
        return send(res, 200, fs.readFileSync(DASHBOARD_HTML), 'text/html; charset=utf-8', {
          'X-Frame-Options': 'DENY',
          'Content-Security-Policy':
            "default-src 'self'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; connect-src 'self' https://api.github.com; img-src 'self' data:",
        });
      }
      if (p === '/api/apps') return await handleApi(req, res, url);
    }
    send(res, 404, { error: 'Not found' });
  } catch (err) {
    send(res, 400, { error: err.message || 'Bad request' });
  }
});

server.listen(PORT, HOST, () => {
  console.log(`App list server on http://${HOST}:${PORT}  (list: /apps.json, dashboard: /dashboard)`);
  console.log(`Data file: ${DATA_FILE}  (${apps.length} links)`);
});
