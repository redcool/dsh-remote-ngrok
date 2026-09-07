// DSH web 前置代理（本机 127.0.0.1:3200）
// 功能：
//   1. Cookie 会话认证（登录一次，WebSocket 握手不再被 401 弹窗——basic-auth 对 WS 无效的替代解）
//   2. 向 HTML 页面注入 AbortSignal.any/timeout polyfill（iOS < 17.4 兼容）
//   3. 剥离 Origin 头：绕开 dsh web browser-trust fence 的 "Origin 须与 Host 精确同源" 校验
//   4. 转发 HTTP + WebSocket 到 127.0.0.1:3080（dsh web）
//   5. dsh web 浏览器会话认证（新版 dsh ≥ 0.1.2-rc.1）：dsh web 要求浏览器先用启动 token
//      换 signed cookie（无则返回 401 "dsh web authentication required"，手机上即"需要 dsh web
//      授权"）。本 proxy 在上游返回该 401 时，对已过本 proxy 认证的访问 302 到
//      /?token=<dsh 启动 token>，由 dsh **原生**完成换票（按 Host 签发 domain 绑定 cookie，
//      302 回干净 /）——不复制 dsh 内部 cookie 格式，天然兼容 dsh 版本升级。
//      token 来源：start_remote_all(.ps1/.bat/.sh) 启动 dsh web 时捕获其打印的 URL 写入
//      proxy/dsh_token.txt；环境变量 DSH_PROXY_DSH_TOKEN 可覆盖。
//   6. 上游 gzip 处理：dsh 上游在远程访问场景会把 HTML 回成 gzip/br；注入 polyfill 必须在
//      明文上做（对压缩流注入会破坏响应，手机表现为连接中断）。故转发前剥离 Accept-Encoding，
//      html 分支再防御性解压（content-encoding: gzip/br/deflate → 明文），并去掉
//      content-encoding/vary 后以 chunked 明文回包。
// 适配版本基线：@deepseek-ai/dsh 系列（dsh / dsh-client-connection / dsh-web-frontend /
//      dsh-web-app）0.1.2-rc.1（2026-09-07 实测）。耦合点清单与 dsh 升级后的再适配指引
//      见 dsh-remote/README.md §13（§13.4 runbook：升级后 ~10 分钟自查）。
// 用法：
//   set DSH_PROXY_USER=dsh && set DSH_PROXY_PASSWORD=你的强密码
//   set DSH_PROXY_DSH_TOKEN=当前 dsh web 的启动 token （可选；缺省读本目录 dsh_token.txt）
//   set DSH_PROXY_TARGET=http://127.0.0.1:3080 （可选；缺省同上）
//   npm install http-proxy   （本项目目录）
//   node server.js
'use strict';
const http = require('http');
const crypto = require('crypto');
const fs = require('fs');
const path = require('path');
const { URL } = require('url');
const zlib = require('zlib');
const httpProxy = require('http-proxy');

const PORT = Number(process.env.DSH_PROXY_PORT || 3200);
const TARGET = process.env.DSH_PROXY_TARGET || 'http://127.0.0.1:3080';
const USERNAME = process.env.DSH_PROXY_USER || 'dsh';
const PASSWORD = process.env.DSH_PROXY_PASSWORD;
if (!PASSWORD) {
  console.error('[dsh-proxy] 必须设置环境变量 DSH_PROXY_PASSWORD（登录密码）后才能启动');
  process.exit(1);
}
const SESSION_TTL_MS = 24 * 3600 * 1000; // 24h

const sessions = new Map(); // token -> expiresAt
const proxy = httpProxy.createProxyServer({ target: TARGET, ws: true, selfHandleResponse: true });

// ---------- 会话 ----------
function grantSession(res) {
  const token = crypto.randomBytes(24).toString('hex');
  sessions.set(token, Date.now() + SESSION_TTL_MS);
  // 惰性清理：每次发新会话时清一次过期项（防 Map 无限增长）
  if (sessions.size > 256) {
    const now = Date.now();
    for (const [k, exp] of sessions) if (now > exp) sessions.delete(k);
  }
  res.setHeader('Set-Cookie', `dsh_session=${token}; Path=/; HttpOnly; SameSite=Lax; Max-Age=${Math.floor(SESSION_TTL_MS / 1000)}`);
}
function sessionOk(req) {
  const m = /(?:^|;\s*)dsh_session=([^;]+)/.exec(req.headers.cookie || '');
  if (!m) return false;
  const exp = sessions.get(m[1]);
  if (!exp) return false;
  if (Date.now() > exp) { sessions.delete(m[1]); return false; }
  return true;
}

// ---------- 登录防爆破：同一来源连续失败 >5 次 → 延迟 1s（内存计数，重启即清零） ----------
const failCount = new Map(); // 来源 -> 连续失败次数
// ngrok 场景 socket.remoteAddress 恒为 127.0.0.1（本地转发）→ 取 X-Forwarded-For 才是真实客户端 ip
function clientIp(req) {
  const xff = req.headers['x-forwarded-for'];
  if (xff) return String(xff).split(',')[0].trim();
  return (req.socket.remoteAddress || '').replace(/^::ffff:/, '');
}
function tooManyFails(ip) {
  const n = failCount.get(ip) || 0;
  if (n >= 5) return true;
  setTimeout(() => failCount.delete(ip), 5 * 60 * 1000); // 5 分钟窗口后清计数
  return false;
}
function recordFail(ip) { failCount.set(ip, (failCount.get(ip) || 0) + 1); }

// ---------- basic-auth 兼容（浏览器记住的旧凭据也能进） ----------
function safeEqual(a, b) {
  const ba = Buffer.from(a), bb = Buffer.from(b);
  if (ba.length !== bb.length) return false;
  return crypto.timingSafeEqual(ba, bb);
}
function basicOk(req) {
  const h = req.headers['authorization'] || '';
  if (!h.startsWith('Basic ')) return false;
  return safeEqual(h.slice(6), Buffer.from(`${USERNAME}:${PASSWORD}`).toString('base64'));
}

// ---------- dsh web 浏览器会话认证（功能 5） ----------
// 新版 dsh（≥ 0.1.2-rc.1）要求浏览器先用"每进程启动 token"换 signed cookie 才能访问根页面
// （无有效 cookie → 401 "dsh web authentication required"，手机页面上即"需要 dsh web 授权"）。
// 本 proxy 不复制 dsh 的 cookie 内部格式，而是把 401 重定向到 <同路径>?token=<启动 token>，
// 交给 dsh 自己完成换票：dsh 按请求 Host 签发 domain 绑定签名 cookie（30 天，跨 dsh 重启有效），
// 302 回干净的 / —— 手机登录一次即全通，且天然兼容 dsh 版本升级。
// token 由 start_remote_all(.ps1/.bat/.sh) 启动 dsh web 时捕获其打印的 URL 写入
// proxy/dsh_token.txt；环境变量 DSH_PROXY_DSH_TOKEN 可覆盖。
function loadDshToken() {
  const fromEnv = (process.env.DSH_PROXY_DSH_TOKEN || '').trim();
  if (fromEnv) return fromEnv;
  try { return fs.readFileSync(path.join(__dirname, 'dsh_token.txt'), 'utf8').trim(); } catch { return ''; }
}

// ---------- 登录页 ----------
const LOGIN_HTML = `<!DOCTYPE html>
<html lang="zh"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>DSH 远程访问</title>
<style>body{font-family:-apple-system,system-ui,sans-serif;background:#0f1219;color:#e6e6e6;display:flex;min-height:100vh;margin:0;align-items:center;justify-content:center}
.card{background:#1a1f2b;padding:36px 40px;border-radius:14px;box-shadow:0 8px 30px rgba(0,0,0,.5);width:320px}
h1{font-size:20px;margin:0 0 22px;color:#7aa2ff}label{display:block;font-size:13px;color:#9aa4b2;margin:12px 0 6px}
input{width:100%;box-sizing:border-box;padding:10px 12px;border:1px solid #2e3748;border-radius:8px;background:#11151d;color:#e6e6e6;font-size:15px}
button{width:100%;margin-top:22px;padding:11px;border:0;border-radius:8px;background:#3d6bff;color:#fff;font-size:15px;font-weight:600;cursor:pointer}
.err{color:#ff7a7a;font-size:13px;margin-top:12px;min-height:18px}</style></head>
<body><form class="card" method="post" action="/__login">
<h1>DSH 远程访问</h1>
<label>用户名</label><input name="u" autocomplete="username" required>
<label>密码</label><input name="p" type="password" autocomplete="current-password" required>
<button type="submit">进入</button>
<div class="err" id="e"></div>
</form>
<script>if(new URLSearchParams(location.search).get('fail'))document.getElementById('e').textContent='用户名或密码错误';</script>
</body></html>`;

// ---------- 浏览器 polyfill（注入 HTML；iOS < 17.4 兼容） ----------
const POLYFILL = `(function(){
  if (typeof AbortSignal !== 'undefined') {
    if (!AbortSignal.timeout) {
      AbortSignal.timeout = function(ms){
        var ctrl = new AbortController();
        setTimeout(function(){ try { ctrl.abort(new DOMException('The operation timed out.','TimeoutError')); } catch(e){ ctrl.abort(); } }, ms);
        return ctrl.signal;
      };
    }
    if (!AbortSignal.any) {
      AbortSignal.any = function(signals){
        var ctrl = new AbortController(); var done = false;
        function fire(src){
          if (done) return; done = true;
          try { if (src && src.reason !== undefined) ctrl.abort(src.reason); else ctrl.abort(new DOMException('Aborted','AbortError')); }
          catch(e){ ctrl.abort(); }
        }
        var arr = signals || [];
        for (var i=0;i<arr.length;i++){ var s=arr[i]; if (s && s.aborted) { fire(s); return ctrl.signal; } }
        for (var j=0;j<arr.length;j++){ var ss=arr[j]; if (ss) ss.addEventListener('abort', function(){ fire(this); }); }
        return ctrl.signal;
      };
    }
  }
  if (typeof Promise !== 'undefined' && typeof Promise.withResolvers !== 'function') {
    Promise.withResolvers = function(){
      var out = {};
      out.promise = new Promise(function(res, rej){ out.resolve = res; out.reject = rej; });
      return out;
    };
  }
  if (typeof URL !== 'undefined' && typeof URL.canParse !== 'function') {
    URL.canParse = function(u, base){ try { new URL(u, base); return true; } catch(e){ return false; } };
  }
  if (typeof Object.hasOwn !== 'function') {
    Object.hasOwn = function(obj, key){ return Object.prototype.hasOwnProperty.call(obj, key); };
  }
  if (typeof Array !== 'undefined') {
    if (typeof Array.prototype.findLast !== 'function') {
      Array.prototype.findLast = function(fn, thisArg){ for (var i=this.length-1;i>=0;i--){ if (fn.call(thisArg, this[i], i, this)) return this[i]; } return undefined; };
      Array.prototype.findLastIndex = function(fn, thisArg){ for (var i=this.length-1;i>=0;i--){ if (fn.call(thisArg, this[i], i, this)) return i; } return -1; };
    }
    if (typeof Array.prototype.at !== 'function') {
      Array.prototype.at = function(n){ n = Math.trunc(n) || 0; if (n < 0) n += this.length; return n >= 0 && n < this.length ? this[n] : undefined; };
    }
  }
})();`;

function injectPolyfill(html) {
  const tag = `<script>${POLYFILL}<\/script>`;
  // 无条件注入（polyfill 幂等：每个 API 都有 typeof 守卫，重复注入无害）。
  // 不要用 html.includes('AbortSignal') 做 guard：页面本身含该字样会跳过注入 → iOS 老设备复发。
  if (html.includes('</head>')) return html.replace('</head>', tag + '</head>');
  return tag + html;
}

// ---------- 请求处理 ----------
const server = http.createServer((req, res) => {
  const u = new URL(req.url, 'http://x');

  // 登录提交
  if (u.pathname === '/__login' && req.method === 'POST') {
    let body = '';
    req.on('data', (c) => (body += c));
    req.on('end', () => {
      const ip = clientIp(req);
      const sp = new URLSearchParams(body);
      const ok = sp.get('u') === USERNAME && sp.get('p') === PASSWORD;
      if (ok) {
        failCount.delete(ip);           // 成功 → 清失败计数
        grantSession(res);
        res.writeHead(302, { Location: '/' });
        res.end();
      } else {
        recordFail(ip);
        const wait = tooManyFails(ip);  // 连续 5 次失败后延迟回应（防爆破）
        setTimeout(() => {
          res.writeHead(302, { Location: '/?fail=1' });
          res.end();
        }, wait ? 1000 : 0);
      }
    });
    return;
  }

  // 未登录 → 登录页（页面类请求），其余给 401（不弹 basic 框）
  const authed = sessionOk(req) || basicOk(req);
  if (!authed) {
    const accept = req.headers.accept || '';
    if (accept.includes('text/html') || u.pathname === '/') {
      res.writeHead(401, { 'Content-Type': 'text/html; charset=utf-8' });
      res.end(LOGIN_HTML);
      return;
    }
    res.writeHead(401, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({ error: 'unauthorized' }));
    return;
  }

  // 已认证 → 转发；剥离 Origin：让 fence 走"无 Origin → 放行"分支（Host 白名单校验仍在）
  delete req.headers.origin;
  // 剥离 Accept-Encoding：dsh 上游在远程访问场景会回 gzip。polyfill 注入依赖明文 HTML，
  // 压缩流注入会损坏响应（手机端即表现为连接中断/超时）——强制上游明文后再注入。
  delete req.headers['accept-encoding'];
  proxy.web(req, res, { target: TARGET }, (err) => {
    res.writeHead(502);
    res.end('proxy error: ' + err.message);
  });
});

// 拦截响应做 polyfill 注入（selfHandleResponse:true 后由本处理器统一回写）
proxy.on('proxyRes', (proxyRes, req, res) => {
  // 功能 5：dsh web 返回 "authentication required"（401，缺浏览器会话）且客户端已过本 proxy 认证
  // → 302 到 /?token=<dsh 启动 token>，由 dsh 原生换票（自愈：已登录过本 proxy 的老会话同样直接救活）
  if (proxyRes.statusCode === 401 && req.method === 'GET') {
    const u = new URL(req.url, 'http://x');
    const hadProxySession = sessionOk(req) || basicOk(req);
    // 已带 ?token= 的换票请求不再二次重定向（防 token 失效时无限 302 循环）
    if (hadProxySession && u.pathname === '/' && !u.searchParams.has('token')) {
      const dshToken = loadDshToken();
      if (dshToken) {
        proxyRes.resume(); // 排空上游 401 响应体
        res.writeHead(302, { 'cache-control': 'no-store', location: '/?token=' + encodeURIComponent(dshToken) });
        res.end();
        console.log('[dsh-proxy] redirect to dsh token exchange (authority=' + String(req.headers.host) + ')');
        return;
      }
    }
  }
  const ct = proxyRes.headers['content-type'] || '';
  if (ct.includes('text/html')) {
    const chunks = [];
    proxyRes.on('data', (c) => chunks.push(c));
    proxyRes.on('end', () => {
      let buf = Buffer.concat(chunks);
      // 防御：即便上游仍回压缩内容（个别上游可能无视 Accept-Encoding 剥离），先还原成明文再注入
      const ce = String(proxyRes.headers['content-encoding'] || '').toLowerCase();
      try {
        if (ce === 'gzip' || ce === 'x-gzip') buf = zlib.gunzipSync(buf);
        else if (ce === 'br') buf = zlib.brotliDecompressSync(buf);
        else if (ce === 'deflate') buf = zlib.inflateSync(buf);
      } catch (err) {
        console.error('[dsh-proxy] decompress error (' + ce + '): ' + err.message + ' — 按原样转发');
      }
      const html = buf.toString('utf8');
      const out = injectPolyfill(html);
      const headers = Object.assign({}, proxyRes.headers);
      delete headers['content-length'];          // 注入后体积变化：旧长度不再成立
      delete headers['transfer-encoding'];       // 上游可能是 chunked 动态渲染（如 Host 非 loopback 时）
      delete headers['connection'];              // hop-by-hop，交由本机 Node 决定
      delete headers['content-encoding'];        // 已解压为明文
      delete headers['vary'];                    // 恒回明文，不再有 AE 变体
      // 不再重算 content-length：不写 Content-Length + res.end() → Node 自动用 Transfer-Encoding: chunked
      // 回包（浏览器同样正确读全，且实测 chunked 走 ngrok 隧道稳定；写死长度反而会在代理/隧道链路触发帧错乱）。
      res.writeHead(proxyRes.statusCode, headers);
      res.end(out);
    });
    proxyRes.on('error', (e) => {               // 上游读流异常：兜底关连接，防挂起
      res.destroy();
    });
  } else {
    res.writeHead(proxyRes.statusCode, proxyRes.headers);
    proxyRes.pipe(res);
    proxyRes.on('error', (e) => res.destroy());
  }
});

// WebSocket 转发（握手带 cookie → 通过；无 cookie → 403 应用层拒绝，不弹 basic 框）
server.on('upgrade', (req, socket, head) => {
  if (!sessionOk(req)) {
    socket.write('HTTP/1.1 403 Forbidden\r\n\r\n');
    socket.destroy();
    return;
  }
  delete req.headers.origin; // 同正文转发：剥 Origin，避免 fence 误拦
  proxy.ws(req, socket, head, { target: TARGET }, (err) => {
    socket.destroy();
  });
});

server.listen(PORT, '127.0.0.1', () => {
  console.log(`[dsh-proxy] listening on http://127.0.0.1:${PORT} -> ${TARGET}`);
});