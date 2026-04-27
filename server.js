const http = require('http');
const fs = require('fs');
const path = require('path');

const PORT = process.env.PORT || 5812;
const HOST = process.env.HOST || '127.0.0.1'; // 默认只监听本机
const AUTH_USER = process.env.AUTH_USER || '';
const AUTH_PASS = process.env.AUTH_PASS || '';

const DATA_FILE = path.join(__dirname, 'data.json');
const INDEX_FILE = path.join(__dirname, 'index.html');

if (!fs.existsSync(DATA_FILE)) {
  fs.writeFileSync(DATA_FILE, JSON.stringify({ lastIncome: 0, categories: [] }));
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
    // 限制请求体大小（最大 64KB）
    let body = '';
    req.on('data', chunk => {
      body += chunk;
      if (body.length > 65536) {
        res.writeHead(413, { 'Content-Type': 'text/plain' });
        res.end('Payload Too Large');
        req.destroy();
      }
    });
    req.on('end', () => {
      try {
        JSON.parse(body);
        fs.writeFileSync(DATA_FILE, body);
        res.writeHead(200, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ ok: true }));
      } catch (e) {
        res.writeHead(400);
        res.end(JSON.stringify({ error: 'invalid JSON' }));
      }
    });
    return;
  }

  if (req.method === 'GET' && (url.pathname === '/' || url.pathname === '/index.html')) {
    try {
      const html = fs.readFileSync(INDEX_FILE, 'utf-8');
      res.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8' });
      res.end(html);
    } catch (e) {
      res.writeHead(404);
      res.end('index.html not found');
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
