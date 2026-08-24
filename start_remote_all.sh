#!/usr/bin/env bash
# ============================================================
# DSH 远程访问 · 一键拉起（macOS / Linux 版，对应 Windows 的 .bat/.ps1）
# 用法：bash start_remote_all.sh
# 链路：手机/浏览器 → ngrok(TLS) → dsh-proxy(127.0.0.1:3200) → dsh web(127.0.0.1:3080)
# 特性：
#   - 自动检测系统与架构，ngrok/ngrok 二进制缺失时自动下载对应版本到 ngrok/
#   - 读 config.json（模板 config.json.temp 复制改名后填写）
#   - dsh web 前台运行：本终端窗口即宿主，Ctrl+C / 关窗口 = 关 dsh
# ============================================================

set -u  # 未定义变量报错（不 set -e：让它跑完所有步骤好排查）

TOOLS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CFG_FILE="$TOOLS_DIR/config.json"
LOG_DIR="$TOOLS_DIR/ngrok"
NROK_BIN="$LOG_DIR/ngrok"

# ---------- 依赖检查 ----------
command -v node >/dev/null 2>&1 || { echo "[!] 未找到 node —— 请先安装 Node.js LTS（https://nodejs.org）"; exit 1; }
command -v curl >/dev/null 2>&1 || { echo "[!] 未找到 curl"; exit 1; }
command -v unzip >/dev/null 2>&1 || { echo "[!] 未找到 unzip（macOS 自带；Linux 装 unzip 包）"; exit 1; }

# ---------- 检测系统/架构 ----------
OS="$(uname -s)"
ARCH="$(uname -m)"
case "$OS-$ARCH" in
  Darwin-arm64)  NROK_PLAT=darwin-arm64 ;;
  Darwin-x86_64|Darwin-i386|Darwin-amd64) NROK_PLAT=darwin-amd64 ;;
  Linux-arm64)   NROK_PLAT=linux-arm64 ;;
  Linux-x86_64|Linux-amd64) NROK_PLAT=linux-amd64 ;;
  *) echo "[!] 不支持的平台: $OS-$ARCH"; exit 1 ;;
esac
echo "[*] 平台: $OS-$ARCH (ngrok $NROK_PLAT)"
NROK_URL="https://bin.equinox.io/c/bNyj1mQVY4c/ngrok-v3-stable-$NROK_PLAT.zip"

# ---------- 读 config.json（node 解析，输出 key=value） ----------
if [ -f "$CFG_FILE" ]; then
  cfg_get() { node -e "const c=require('$CFG_FILE'); process.stdout.write(String(c['$1']||''));"; }
  TOKEN="$(cfg_get ngrok_token)"
  DSH_INSTALL_DIR="$(cfg_get dsh_install_dir)"
  DSH_HOME="$(cfg_get dsh_home)"
  NGROK_HOST="$(cfg_get ngrok_host)"
  PROXY_USER="$(cfg_get proxy_user)"
  PROXY_PASS="$(cfg_get proxy_password)"
else
  echo "[!] 缺 config.json —— 复制 config.json.temp 为 config.json 并填写"
  exit 1
fi

# proxy 凭据：优先环境变量，其次 config.json
DSH_PROXY_USER="${DSH_PROXY_USER:-$PROXY_USER}"
DSH_PROXY_PASSWORD="${DSH_PROXY_PASSWORD:-$PROXY_PASS}"
export DSH_PROXY_USER DSH_PROXY_PASSWORD

# ---------- ngrok authtoken（config → 询问写回） ----------
test_token() {
  local t="$1"
  [ "${#t}" -ge 20 ] || return 1
  case "$t" in *://*) return 1;; esac
  case "$t" in *YOUR_*|*TODO*|*example*|*示例*|*REPLACE*) return 1;; esac
  [[ "$t" =~ ^[A-Za-z0-9_\-]{20,}$ ]] || return 1
  return 0
}
save_token() { node -e "const fs=require('fs');const c=JSON.parse(fs.readFileSync('$CFG_FILE','utf8'));c.ngrok_token='$1';fs.writeFileSync('$CFG_FILE',JSON.stringify(c,null,2));"; }

if ! test_token "$TOKEN"; then
  echo "──────────────────────────────────────────────"
  echo " 需要 ngrok authtoken（config.json 缺失或无效）—— https://dashboard.ngrok.com → Your Authtoken"
  read -r -p " authtoken: " TOKEN
  TOKEN="$(echo "$TOKEN" | xargs)"
  if test_token "$TOKEN"; then save_token "$TOKEN"; echo "[+] 已写回 config.json"; else
    echo "[!] 输入不像有效 authtoken；ngrok 可能启动失败"; TOKEN=""
  fi
fi
[ -n "$TOKEN" ] && export NGROK_AUTHTOKEN="$TOKEN"

# ---------- ① dsh-proxy（3200） ----------
port_listen() { nc -z 127.0.0.1 "$1" 2>/dev/null; }
if port_listen 3200; then
  echo "[*] proxy 已在跑（3200）— 跳过"
else
  echo "[*] 启动 dsh-proxy（3200）..."
  ( cd "$TOOLS_DIR/proxy" && node server.js >"$LOG_DIR/proxy.log" 2>&1 & )
  sleep 2
  port_listen 3200 && echo "[+] proxy 3200 在线" || echo "[!] proxy 启动失败（看 $LOG_DIR/proxy.log）"
fi

# ---------- ② ngrok（→3200） ----------
mkdir -p "$LOG_DIR"
if port_listen 4040; then
  echo "[*] ngrok 已在跑（4040）— 跳过"
elif [ ! -x "$NROK_BIN" ]; then
  echo "[*] 未找到 $NROK_BIN -> 自动下载 $NROK_PLAT 版..."
  curl -fsSL "$NROK_URL" -o "$LOG_DIR/ngrok.zip" || { echo "[!] 下载失败: $NROK_URL"; exit 1; }
  ( cd "$LOG_DIR" && unzip -o ngrok.zip >/dev/null 2>&1 && chmod +x ngrok && rm -f ngrok.zip )
  echo "[+] 已安装 ngrok (v$($NROK_BIN version | sed 's/ngrok version //' 2>/dev/null || echo '?'))"
fi
if port_listen 4040; then
  :
elif [ -x "$NROK_BIN" ]; then
  if [ -n "$NGROK_HOST" ]; then
    echo "[*] 启动 ngrok → 3200（静态域名 $NGROK_HOST）..."
    "$NROK_BIN" http 3200 --url="$NGROK_HOST" --log=stdout >"$LOG_DIR/ngrok.log" 2>&1 &
  else
    echo "[*] 启动 ngrok → 3200（config 未填 ngrok_host，用临时随机域名）..."
    "$NROK_BIN" http 3200 --log=stdout >"$LOG_DIR/ngrok.log" 2>&1 &
  fi
  # 等隧道就绪（最多 ~15s）
  TUNNEL_URL=""
  for i in $(seq 1 15); do
    sleep 1
    TUNNEL_URL="$(curl -fsS http://127.0.0.1:4040/api/tunnels 2>/dev/null | node -e "let d='';process.stdin.on('data',c=>d+=c).on('end',()=>{try{const t=JSON.parse(d).tunnels;process.stdout.write(t&&t[0]?t[0].public_url:'')}catch(e){}})" )"
    [ -n "$TUNNEL_URL" ] && break
  done
  if [ -n "$TUNNEL_URL" ]; then
    echo "[+] ngrok: $TUNNEL_URL → http://127.0.0.1:3200"
    [ -z "$NGROK_HOST" ] && echo "    提示：注册 ngrok 免费送 .ngrok-free.dev 静态域名，填入 config.json 的 ngrok_host 可固定 URL"
  else
    echo "[!] ngrok 未就绪（看 $LOG_DIR/ngrok.log；authtoken 无效或已到免费连接上限都会这样）"
    tail -3 "$LOG_DIR/ngrok.log" 2>/dev/null
    TUNNEL_URL=""
  fi
else
  echo "[!] ngrok 二进制不可执行（$NROK_BIN）"
fi

# ---------- ③ dsh web（3080，前台运行 = 本终端即宿主） ----------
TUNNEL_HOST=""
[ -n "$TUNNEL_URL" ] && TUNNEL_HOST="$(echo "$TUNNEL_URL" | sed -E 's#^https?://##; s#/.*$##')"
[ -z "$TUNNEL_HOST" ] && TUNNEL_HOST="$NGROK_HOST"

if port_listen 3080; then
  echo "[*] dsh web 已在跑（3080）— 跳过（若要重启请先关掉旧的 dsh web 终端）"
else
  if [ -z "$DSH_INSTALL_DIR" ] || [ ! -d "$DSH_INSTALL_DIR" ]; then
    echo "[!] 无法启动 dsh web：config.json 未正确配置 dsh_install_dir（当前: '$DSH_INSTALL_DIR'）"
  else
    # dsh 数据目录（对应 DSH_HOME）——必须在启动前设置
    [ -n "$DSH_HOME" ] && export DSH_HOME="$DSH_HOME"
    BIN_JS="$DSH_INSTALL_DIR/node_modules/@deepseek-ai/dsh/lib/bin.js"
    echo ""
    echo "=================================================="
    echo " 启动 dsh web → 本终端即宿主（Ctrl+C / 关窗口 = 关闭 dsh）"
    echo " 公网: ${TUNNEL_URL:-（ngrok 未就绪）}"
    echo " 本机: http://127.0.0.1:3080"
    echo "=================================================="
    echo ""
    # 前台阻塞运行；Ctrl+C / 关终端 → dsh 停止
    if [ -f "$BIN_JS" ]; then
      node "$BIN_JS" web --port 3080 --trusted-host "$TUNNEL_HOST" --no-open
    else
      # 兜底：npm 全局安装的 dsh
      dsh web --port 3080 --trusted-host "$TUNNEL_HOST" --no-open
    fi
    echo "[*] dsh web 已停止"
  fi
fi