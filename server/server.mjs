// 대시보드 서버. 수집기가 쓴 SQLite를 읽어 JSON API와 정적 페이지를 localhost로 제공한다.
// 의존성 없음: Node 내장 node:sqlite만 사용한다.
import http from 'node:http';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { DatabaseSync } from 'node:sqlite';
import { fileURLToPath } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const dataDir = process.env.FOCUS_DATA_DIR || path.join(os.homedir(), 'Library/Application Support/FocusTracker');
const dbPath = path.join(dataDir, 'tracker.db');
const configPath = path.join(dataDir, 'config.json');
const PORT = Number(process.env.PORT) || 4317;

const DEFAULT_CONFIG = {
  excludedApps: ['com.1password.1password', '1Password', 'com.bitwarden.desktop', 'com.apple.keychainaccess', 'com.apple.Passwords'],
  focusApps: [],
  goalHours: 2,
};
const STREAK_LOOKBACK_DAYS = 60;
const ACTIVE_WITHIN_SEC = 20; // 수집기는 5초마다 ended_at을 갱신한다.
const SLOTS = 8; // 앱별 색은 처음 본 순서로 고정, 9번째부터는 "기타".

let db = null;
function getDb() {
  if (!db && fs.existsSync(dbPath)) {
    db = new DatabaseSync(dbPath);
    db.exec('PRAGMA busy_timeout=3000');
  }
  return db;
}

function readConfig() {
  try {
    return { ...DEFAULT_CONFIG, ...JSON.parse(fs.readFileSync(configPath, 'utf8')) };
  } catch {
    return { ...DEFAULT_CONFIG };
  }
}

function writeConfig(input) {
  const strList = (v) => (Array.isArray(v) ? v.filter((s) => typeof s === 'string' && s.trim()).map((s) => s.trim()) : null);
  const cur = readConfig();
  const next = {
    excludedApps: strList(input.excludedApps) ?? cur.excludedApps,
    focusApps: strList(input.focusApps) ?? cur.focusApps,
    goalHours: Number.isFinite(input.goalHours) && input.goalHours >= 0 && input.goalHours <= 24 ? input.goalHours : cur.goalHours,
  };
  fs.mkdirSync(dataDir, { recursive: true });
  fs.writeFileSync(configPath, JSON.stringify(next, null, 2));
  return next;
}

// ---- 시간 계산 (서버와 수집기는 같은 Mac이므로 로컬 타임존이 같다) ----

const nowSec = () => Math.floor(Date.now() / 1000);
const dayStart = (sec) => {
  const d = new Date(sec * 1000);
  return Math.floor(new Date(d.getFullYear(), d.getMonth(), d.getDate()).getTime() / 1000);
};
const nextDayStart = (sec) => {
  const d = new Date(sec * 1000);
  return Math.floor(new Date(d.getFullYear(), d.getMonth(), d.getDate() + 1).getTime() / 1000);
};

function sessionsBetween(from, to) {
  const d = getDb();
  if (!d) return [];
  return d
    .prepare('SELECT app, started_at AS s, ended_at AS e FROM sessions WHERE ended_at > ? AND started_at < ? ORDER BY started_at')
    .all(from, to)
    .map((r) => ({ app: r.app, s: Math.max(r.s, from), e: Math.min(r.e, to) }))
    .filter((r) => r.e > r.s);
}

/** 세션을 날짜 경계로 쪼개 날짜(0시 epoch) -> {앱: 초} 로 모은다. */
function perDay(rows) {
  const days = new Map();
  for (const r of rows) {
    for (let cur = r.s; cur < r.e; ) {
      const ds = dayStart(cur);
      const end = Math.min(r.e, nextDayStart(cur));
      const apps = days.get(ds) ?? new Map();
      apps.set(r.app, (apps.get(r.app) ?? 0) + (end - cur));
      days.set(ds, apps);
      cur = end;
    }
  }
  return days;
}

const sum = (apps, filter = () => true) => [...apps].reduce((t, [a, sec]) => (filter(a) ? t + sec : t), 0);

/** 앱 -> 색 슬롯(0~7). 처음 기록된 순서로 고정돼 필터나 순위가 바뀌어도 색이 변하지 않는다. */
function colorSlots() {
  const d = getDb();
  if (!d) return {};
  const rows = d.prepare('SELECT app, MIN(started_at) AS first FROM sessions GROUP BY app ORDER BY first, app').all();
  return Object.fromEntries(rows.map((r, i) => [r.app, i < SLOTS ? i : -1]));
}

// ---- API ----

function apiStatus() {
  const d = getDb();
  const last = d?.prepare('SELECT app, started_at AS s, ended_at AS e FROM sessions ORDER BY id DESC LIMIT 1').get();
  const now = nowSec();
  const active = !!last && now - last.e <= ACTIVE_WITHIN_SEC;
  return { now, active, app: active ? last.app : null, since: active ? last.s : null, lastApp: last?.app ?? null };
}

function apiToday() {
  const now = nowSec();
  const from = dayStart(now);
  const rows = sessionsBetween(from, now);
  const cfg = readConfig();
  const apps = perDay(rows).get(from) ?? new Map();
  const ranking = [...apps].map(([app, sec]) => ({ app, sec })).sort((a, b) => b.sec - a.sec);
  return {
    from,
    now,
    totalSec: sum(apps),
    focusSec: sum(apps, (a) => cfg.focusApps.includes(a)),
    ranking,
    timeline: rows.map((r) => ({ app: r.app, s: r.s, e: r.e })),
    slots: colorSlots(),
  };
}

function apiWeek() {
  const now = nowSec();
  const cfg = readConfig();
  const lookbackFrom = dayStart(now - STREAK_LOOKBACK_DAYS * 86400);
  const days = perDay(sessionsBetween(lookbackFrom, now));
  const goalSec = cfg.goalHours * 3600;
  const streakOn = cfg.focusApps.length > 0 && goalSec > 0;
  const focusOf = (apps) => sum(apps, (a) => cfg.focusApps.includes(a));

  // 오늘부터 6일 전까지 (오래된 날 -> 오늘)
  const list = [];
  let ds = dayStart(now);
  for (let i = 0; i < 7; i++) {
    const apps = days.get(ds) ?? new Map();
    list.unshift({ day: ds, totalSec: sum(apps), focusSec: focusOf(apps) });
    ds = dayStart(ds - 1);
  }

  // 스트릭: 오늘이 아직 목표 전이면 오늘은 건너뛰고 어제부터 센다.
  let streak = null;
  if (streakOn) {
    streak = 0;
    ds = dayStart(now);
    const achieved = (d) => focusOf(days.get(d) ?? new Map()) >= goalSec;
    if (!achieved(ds)) ds = dayStart(ds - 1);
    while (ds >= lookbackFrom && achieved(ds)) {
      streak++;
      ds = dayStart(ds - 1);
    }
  }
  return { days: list, streak, goalHours: cfg.goalHours, streakOn };
}

function apiConfig() {
  const cfg = readConfig();
  const d = getDb();
  const known = d
    ? d.prepare('SELECT app, SUM(ended_at - started_at) AS sec FROM sessions GROUP BY app ORDER BY sec DESC').all().map((r) => ({ app: r.app, sec: r.sec }))
    : [];
  return { ...cfg, knownApps: known };
}

// ---- HTTP ----

const json = (res, code, body) => {
  res.writeHead(code, { 'content-type': 'application/json; charset=utf-8', 'cache-control': 'no-store' });
  res.end(JSON.stringify(body));
};

const server = http.createServer((req, res) => {
  // DNS 리바인딩 방지: localhost 호스트명으로 온 요청만 받는다.
  const host = (req.headers.host || '').split(':')[0];
  if (host !== 'localhost' && host !== '127.0.0.1') return json(res, 403, { error: 'forbidden' });

  const url = new URL(req.url, 'http://localhost');
  try {
    if (req.method === 'GET' && url.pathname === '/api/status') return json(res, 200, apiStatus());
    if (req.method === 'GET' && url.pathname === '/api/today') return json(res, 200, apiToday());
    if (req.method === 'GET' && url.pathname === '/api/week') return json(res, 200, apiWeek());
    if (req.method === 'GET' && url.pathname === '/api/config') return json(res, 200, apiConfig());
    if (req.method === 'PUT' && url.pathname === '/api/config') {
      // application/json만 허용: 다른 사이트의 폼 전송으로는 설정을 바꿀 수 없다.
      if (!(req.headers['content-type'] || '').startsWith('application/json')) return json(res, 415, { error: 'json only' });
      let body = '';
      req.on('data', (c) => {
        body += c;
        if (body.length > 100_000) req.destroy();
      });
      req.on('end', () => {
        try {
          writeConfig(JSON.parse(body));
          json(res, 200, apiConfig());
        } catch {
          json(res, 400, { error: 'bad json' });
        }
      });
      return;
    }
    if (req.method === 'GET' && (url.pathname === '/' || url.pathname === '/index.html')) {
      res.writeHead(200, { 'content-type': 'text/html; charset=utf-8', 'cache-control': 'no-store' });
      return res.end(fs.readFileSync(path.join(here, 'public/index.html')));
    }
    json(res, 404, { error: 'not found' });
  } catch (err) {
    json(res, 500, { error: String(err?.message ?? err) });
  }
});

server.on('error', (err) => {
  console.error(err.code === 'EADDRINUSE' ? `포트 ${PORT}이 이미 사용 중입니다.` : err);
  process.exit(1);
});
server.listen(PORT, '127.0.0.1', () => console.log(`대시보드: http://localhost:${PORT}`));
