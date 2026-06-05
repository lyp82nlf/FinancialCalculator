const http = require('http');
const fs = require('fs');
const path = require('path');
const { execFileSync } = require('child_process');

const PORT = process.env.PORT || 5812;
const HOST = process.env.HOST || '127.0.0.1'; // 默认只监听本机
const AUTH_USER = process.env.AUTH_USER || '';
const AUTH_PASS = process.env.AUTH_PASS || '';

const DATA_FILE = path.join(__dirname, 'data.json');
const INDEX_FILE = path.join(__dirname, 'index.html');
const HISTORY_FILE = path.join(__dirname, 'history.html');
const SNAPSHOT_DB_SCRIPT = path.join(__dirname, 'snapshot_db.py');
const MAX_CONFIG_BODY_SIZE = 65536;
const MAX_SNAPSHOT_BODY_SIZE = 512 * 1024;

if (!fs.existsSync(DATA_FILE)) {
  fs.writeFileSync(DATA_FILE, JSON.stringify({ lastIncome: 0, categories: [] }));
}

function sendJson(res, status, payload) {
  res.writeHead(status, { 'Content-Type': 'application/json; charset=utf-8' });
  res.end(JSON.stringify(payload));
}

function readJsonBody(req, res, maxSize, onDone) {
  let body = '';
  req.on('data', chunk => {
    body += chunk;
    if (body.length > maxSize) {
      res.writeHead(413, { 'Content-Type': 'text/plain' });
      res.end('Payload Too Large');
      req.destroy();
    }
  });
  req.on('end', () => {
    try {
      onDone(JSON.parse(body || '{}'));
    } catch (e) {
      sendJson(res, 400, { ok: false, error: 'invalid_json' });
    }
  });
}

function currentMonthKey() {
  const now = new Date();
  return `${now.getFullYear()}-${String(now.getMonth() + 1).padStart(2, '0')}`;
}

function runSnapshotDb(command, payload = {}) {
  const output = execFileSync('python3', [SNAPSHOT_DB_SCRIPT, command], {
    input: JSON.stringify(payload),
    encoding: 'utf8',
    maxBuffer: 1024 * 1024
  });
  return JSON.parse(output || '{}');
}

try {
  runSnapshotDb('init');
} catch (e) {
  console.error('SQLite 初始化失败:', e.message);
}

// Basic Auth 校验
function checkAuth(req, res) {
  if (!AUTH_USER) return true; // 未配置则跳过
  const authHeader = req.headers['authorization'] || '';
  if (!authHeader.startsWith('Basic ')) {
    res.writeHead(401, { 'WWW-Authenticate': 'Basic realm="Finance"', 'Content-Type': 'text/plain' });
    res.end('Unauthorized');
    return false;
  }
  const decoded = Buffer.from(authHeader.slice(6), 'base64').toString('utf-8');
  const colonIdx = decoded.indexOf(':');
  const user = decoded.slice(0, colonIdx);
  const pass = decoded.slice(colonIdx + 1);
  if (user === AUTH_USER && pass === AUTH_PASS) return true;
  res.writeHead(401, { 'WWW-Authenticate': 'Basic realm="Finance"', 'Content-Type': 'text/plain' });
  res.end('Unauthorized');
  return false;
}

// 简单限速（每 IP 每秒最多 20 次请求）
const rateLimitMap = new Map();
function rateLimit(req, res) {
  const ip = req.socket.remoteAddress;
  const now = Date.now();
  const entry = rateLimitMap.get(ip) || { count: 0, start: now };
  if (now - entry.start > 1000) { entry.count = 0; entry.start = now; }
  entry.count++;
  rateLimitMap.set(ip, entry);
  if (entry.count > 20) {
    res.writeHead(429, { 'Content-Type': 'text/plain' });
    res.end('Too Many Requests');
    return false;
  }
  return true;
}

const server = http.createServer((req, res) => {
  // 安全头
  res.setHeader('X-Content-Type-Options', 'nosniff');
  res.setHeader('X-Frame-Options', 'DENY');
  res.setHeader('X-XSS-Protection', '1; mode=block');

  if (!rateLimit(req, res)) return;
  if (!checkAuth(req, res)) return;

  const url = new URL(req.url, `http://${HOST}:${PORT}`);

  if (req.method === 'GET' && url.pathname === '/api/config') {
    try {
      const data = fs.readFileSync(DATA_FILE, 'utf-8');
      res.writeHead(200, { 'Content-Type': 'application/json' });
      res.end(data);
    } catch (e) {
      res.writeHead(500);
      res.end(JSON.stringify({ error: 'read failed' }));
    }
    return;
  }

  if (req.method === 'POST' && url.pathname === '/api/config') {
    readJsonBody(req, res, MAX_CONFIG_BODY_SIZE, data => {
      try {
        fs.writeFileSync(DATA_FILE, JSON.stringify(data));
        sendJson(res, 200, { ok: true });
      } catch (e) {
        sendJson(res, 500, { ok: false, error: 'write_failed' });
      }
    });
    return;
  }

  if (req.method === 'POST' && url.pathname === '/api/snapshots/current') {
    readJsonBody(req, res, MAX_SNAPSHOT_BODY_SIZE, payload => {
      try {
        payload.monthKey = payload.monthKey || currentMonthKey();
        const result = runSnapshotDb('save-current', payload);
        sendJson(res, result.ok ? 200 : 400, result);
      } catch (e) {
        sendJson(res, 500, { ok: false, error: 'snapshot_save_failed' });
      }
    });
    return;
  }

  if (req.method === 'GET' && url.pathname === '/api/snapshots/current') {
    try {
      const monthKey = url.searchParams.get('monthKey') || currentMonthKey();
      const result = runSnapshotDb('get-current', { monthKey });
      sendJson(res, result.ok ? 200 : 404, result);
    } catch (e) {
      sendJson(res, 500, { ok: false, error: 'snapshot_read_failed' });
    }
    return;
  }

  if (req.method === 'GET' && url.pathname === '/api/history') {
    try {
      const result = runSnapshotDb('history', {
        year: url.searchParams.get('year') || '',
        month: url.searchParams.get('month') || '',
        assignee: url.searchParams.get('assignee') || '',
        itemKeyword: url.searchParams.get('itemKeyword') || ''
      });
      sendJson(res, result.ok ? 200 : 400, result);
    } catch (e) {
      sendJson(res, 500, { ok: false, error: 'history_query_failed' });
    }
    return;
  }

  if (req.method === 'GET' && (url.pathname === '/' || url.pathname === '/index.html' || url.pathname === '/history.html')) {
    try {
      const file = url.pathname === '/history.html' ? HISTORY_FILE : INDEX_FILE;
      const html = fs.readFileSync(file, 'utf-8');
      res.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8' });
      res.end(html);
    } catch (e) {
      res.writeHead(404);
      res.end('html not found');
    }
    return;
  }

  res.writeHead(404);
  res.end('Not found');
});

server.listen(PORT, HOST, () => {
  console.log(`✅ 财务账本已启动: http://${HOST}:${PORT}`);
  console.log(`🔒 Basic Auth: ${AUTH_USER ? '已启用' : '未启用'}`);
  console.log(`📁 数据路径: ${DATA_FILE}`);
});
