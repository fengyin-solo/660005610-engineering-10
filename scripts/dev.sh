#!/usr/bin/env bash
# ============================================================================
# DAG 工作流引擎 —— 本地开发统一入口
#
# 一条可反复跑通的流程，启动(start)与构建检查(check)共用同一套步骤：
#   预检 → 按锁文件安装依赖(缓存复用) → 统一构建检查 → 启动(沿用原运行方式)
#
# 用法:
#   scripts/dev.sh            # 等同 all:setup + check + start，一条命令跑通
#   scripts/dev.sh all
#   scripts/dev.sh setup      # 预检 + 按锁文件安装前后端依赖
#   scripts/dev.sh check      # 统一构建检查：前端 vue-tsc+vite build，后端编译+导入
#   scripts/dev.sh start      # 跑 setup + check，然后启动前后端(与原来手动启动一致)
#   scripts/dev.sh stop       # 停止由本脚本启动的前后端进程
#   scripts/dev.sh status     # 查看运行状态
#   scripts/dev.sh logs [fe|be]   # 查看日志(默认全部)
#   scripts/dev.sh clean      # 清理上次的中间产物(保留依赖与安装缓存)
#   scripts/dev.sh lock-frontend  # 按 package.json 重新生成 package-lock.json
#   scripts/dev.sh lock-backend   # 按 requirements.txt 重新生成 requirements.lock.txt
#
# 可覆盖的环境变量:
#   FRONTEND_PORT=3000  BACKEND_PORT=8000
#   PIP_CACHE_DIR(默认 .cache/pip)  NPM_CONFIG_CACHE(默认 .cache/npm)
#   FORCE_PIP=1 强制重建后端虚拟环境   FORCE_NPM=1 强制重装前端依赖
#   BACKEND_RELOAD=1 以 --reload 方式启动 uvicorn
# ============================================================================
set -uo pipefail

# ---- 路径 ----
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FRONTEND_DIR="$ROOT_DIR/frontend"
BACKEND_DIR="$ROOT_DIR/backend"
RUN_DIR="$ROOT_DIR/.dev"
CACHE_DIR="$ROOT_DIR/.cache"
VENV_DIR="$BACKEND_DIR/.venv"
LOCK_REQ="$BACKEND_DIR/requirements.lock.txt"
SRC_REQ="$BACKEND_DIR/requirements.txt"

# ---- 端口 / 环境变量默认值 ----
FRONTEND_PORT="${FRONTEND_PORT:-3000}"
BACKEND_PORT="${BACKEND_PORT:-8000}"
export PIP_CACHE_DIR="${PIP_CACHE_DIR:-$CACHE_DIR/pip}"
export NPM_CONFIG_CACHE="${NPM_CONFIG_CACHE:-$CACHE_DIR/npm}"
export PIP_DISABLE_PIP_VERSION_CHECK=1
export PYTHONDONTWRITEBYTECODE=1

mkdir -p "$RUN_DIR" "$CACHE_DIR" "$PIP_CACHE_DIR" "$NPM_CONFIG_CACHE"

BE_PIDFILE="$RUN_DIR/backend.pid"
FE_PIDFILE="$RUN_DIR/frontend.pid"
BE_LOG="$RUN_DIR/backend.log"
FE_LOG="$RUN_DIR/frontend.log"
SETUP_LOG="$RUN_DIR/setup.log"
CHECK_LOG="$RUN_DIR/check.log"

# ---- 颜色与步骤输出 ----
if [ -t 1 ] && command -v tput >/dev/null 2>&1 && [ "$(tput colors 2>/dev/null)" -ge 8 ]; then
  C_STEP=$'\033[1;34m'; C_OK=$'\033[1;32m'; C_WARN=$'\033[1;33m'
  C_ERR=$'\033[1;31m'; C_DIM=$'\033[2m'; C_RST=$'\033[0m'
else
  C_STEP=''; C_OK=''; C_WARN=''; C_ERR=''; C_DIM=''; C_RST=''
fi

CURRENT_STEP=""
step() { CURRENT_STEP="$1"; echo; echo "${C_STEP}▶ [$1]${C_RST} $2"; }
info() { echo "  $1"; }
ok()   { echo "${C_OK}  ✓ $1${C_RST}"; }
warn() { echo "${C_WARN}  ! $1${C_RST}"; }
err()  { echo "${C_ERR}  ✗ $1${C_RST}" >&2; }

# 失败时统一报告：卡在哪个步骤、原因、完整日志位置
die() {
  local msg="$1"; local logfile="${2:-}"
  err "$msg"
  err "失败步骤: ${CURRENT_STEP:-未知}"
  [ -n "$logfile" ] && [ -f "$logfile" ] && err "完整日志: $logfile (可用 tail -n 50 查看)"
  exit 1
}

# 运行命令并把输出同时写入日志；失败即按步骤报告
run_logged() {
  local logfile="$1"; shift
  local ec=0
  echo -e "\n$ $*" >>"$logfile"
  "$@" >>"$logfile" 2>&1 || ec=$?
  if [ "$ec" -ne 0 ]; then
    echo "----- 日志末尾(40 行) -----" >&2
    tail -n 40 "$logfile" >&2 2>/dev/null || true
    die "命令失败(退出码 $ec): $*" "$logfile"
  fi
}

# ---- 进程 / 端口工具 ----
_pid_alive() { kill -0 "$1" 2>/dev/null; }

port_pid() {
  # 返回监听指定端口的 PID（尽力而为，按可用工具探测）
  local port="$1"
  if command -v lsof >/dev/null 2>&1; then
    lsof -ti tcp:"$port" -sTCP:LISTEN 2>/dev/null | head -1
  elif command -v ss >/dev/null 2>&1; then
    ss -ltnpH "sport = :$port" 2>/dev/null | grep -oE 'pid=[0-9]+' | head -1 | cut -d= -f2
  fi
}

# 不依赖 lsof/ss：直接尝试绑定端口（Python 优先）
port_free() {
  local port="$1"
  if command -v python3 >/dev/null 2>&1; then
    python3 - "$port" <<'PYEOF'
import socket, sys
s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
try:
    s.bind(("127.0.0.1", int(sys.argv[1])))
except OSError:
    sys.exit(1)
finally:
    s.close()
sys.exit(0)
PYEOF
  else
    ! (exec 3<>"/dev/tcp/127.0.0.1/$port") 2>/dev/null || { exec 3>&-; return 1; }
  fi
}

# 给出占用端口的描述信息（工具缺失时给出排查命令）
port_owner_hint() {
  local port="$1" pid
  pid="$(port_pid "$port" || true)"
  if [ -n "$pid" ]; then
    ps -o pid=,command= -p "$pid" 2>/dev/null | head -1
  else
    echo "未知(可执行 lsof -i tcp:$port 或 ss -ltnp 'sport = :$port' 查看)"
  fi
}

# ---- 命令存在性 ----
need() {
  command -v "$1" >/dev/null 2>&1 || die "缺少必需命令: $1。请先安装后重跑。"
}

# ============================================================================
# 步骤 1：预检（解释器、工具链、端口）
# ============================================================================
preflight() {
  step "1/4" "预检运行环境"

  need python3
  need npm

  node_major="$(node -p 'process.versions.node.split(".")[0]' 2>/dev/null || echo 0)"
  if [ "$node_major" -lt 18 ]; then
    die "Node.js 版本过低(当前 $(node --version))，Vite 5 需要 Node 18+，推荐 20 LTS。"
  fi
  ok "Node $(node --version) / npm $(npm --version)"
  ok "Python $(python3 --version 2>&1)"
}

# 仅检查“本次真正需要启动”的服务端口；已由本脚本管理且存活的服务视为复用
check_start_ports() {
  info "端口检查: 后端 :$BACKEND_PORT  前端 :$FRONTEND_PORT"

  local be_running=0 fe_running=0
  if [ -f "$BE_PIDFILE" ] && _pid_alive "$(cat "$BE_PIDFILE")"; then be_running=1; fi
  if [ -f "$FE_PIDFILE" ] && _pid_alive "$(cat "$FE_PIDFILE")"; then fe_running=1; fi

  if [ "$be_running" = "1" ]; then
    ok "后端已在运行(pid $(cat "$BE_PIDFILE"))，复用现有进程"
  elif ! port_free "$BACKEND_PORT"; then
    echo "${C_ERR}      端口 $BACKEND_PORT 已被占用: $(port_owner_hint "$BACKEND_PORT")${C_RST}"
    echo "${C_ERR}      若是上次残留的后端进程，执行: scripts/dev.sh stop${C_RST}"
    echo "${C_ERR}      或改用其他端口: BACKEND_PORT=8001 scripts/dev.sh start${C_RST}"
    die "后端端口 $BACKEND_PORT 不可用"
  fi

  if [ "$fe_running" = "1" ]; then
    ok "前端已在运行(pid $(cat "$FE_PIDFILE"))，复用现有进程"
  elif ! port_free "$FRONTEND_PORT"; then
    echo "${C_ERR}      端口 $FRONTEND_PORT 已被占用: $(port_owner_hint "$FRONTEND_PORT")${C_RST}"
    echo "${C_ERR}      若是上次残留的前端进程，执行: scripts/dev.sh stop${C_RST}"
    echo "${C_ERR}      或改用其他端口: FRONTEND_PORT=3001 scripts/dev.sh start${C_RST}"
    die "前端端口 $FRONTEND_PORT 不可用"
  fi

  if [ "$be_running" = "0" ] || [ "$fe_running" = "0" ]; then
    ok "待启动端口 $BACKEND_PORT / $FRONTEND_PORT 均空闲"
  fi
}

# ============================================================================
# 步骤 2：按锁文件安装依赖（前后端；安装缓存复用）
# ============================================================================

# ---- 后端虚拟环境 & pip ----
venv_python_ok() {
  [ -x "$VENV_DIR/bin/python" ] || return 1
  "$VENV_DIR/bin/python" -c 'import sys' >/dev/null 2>&1 || return 1
  # 检测虚拟环境是否来自其他平台/损坏（解释器软链失效、版本目录缺失）
  "$VENV_DIR/bin/python" - <<'PYEOF'
import importlib.util, sys
sys.path = [p for p in sys.path if p]
if importlib.util.find_spec("fastapi") is None:
    sys.exit(1)
PYEOF
}

venv_pip() { "$VENV_DIR/bin/pip" "$@"; }

ensure_venv() {
  local need_create=0
  if [ "${FORCE_PIP:-0}" = "1" ]; then need_create=1
  elif ! venv_python_ok; then need_create=1; fi

  if [ "$need_create" = "1" ]; then
    info "创建后端虚拟环境: $VENV_DIR"
    rm -rf "$VENV_DIR"
    if ! python3 -m venv "$VENV_DIR" >>"$SETUP_LOG" 2>&1; then
      warn "python3 -m venv 失败（常见于 Debian 系缺少 python3-venv / ensurepip），改用 --without-pip 引导"
      python3 -m venv --without-pip "$VENV_DIR" >>"$SETUP_LOG" 2>&1 \
        || die "无法创建虚拟环境，请安装 python3-venv 后重试" "$SETUP_LOG"
    fi
    if [ ! -x "$VENV_DIR/bin/pip" ]; then
      info "虚拟环境内没有 pip，使用 get-pip.py 引导（已缓存可离线复用）"
      local getpip="$CACHE_DIR/get-pip.py"
      if [ ! -s "$getpip" ]; then
        if command -v curl >/dev/null 2>&1; then
          curl -fsSL https://bootstrap.pypa.io/get-pip.py -o "$getpip" 2>>"$SETUP_LOG"
        else
          wget -qO "$getpip" https://bootstrap.pypa.io/get-pip.py 2>>"$SETUP_LOG"
        fi
      fi
      [ -s "$getpip" ] || die "无法取得 get-pip.py（网络不通？），可手动放到 $getpip 后重跑" "$SETUP_LOG"
      run_logged "$SETUP_LOG" "$VENV_DIR/bin/python" "$getpip"
    fi
    venv_pip install --upgrade pip >>"$SETUP_LOG" 2>&1 \
      && ok "虚拟环境与 pip 就绪" \
      || die "pip 自举失败" "$SETUP_LOG"
  else
    ok "后端虚拟环境已存在且可用（需要强制重建: FORCE_PIP=1）"
  fi
}

install_backend() {
  step "2/4 · 后端" "安装后端依赖（requirements.lock.txt，pip 缓存: $PIP_CACHE_DIR）"
  [ -f "$LOCK_REQ" ] || die "缺少 $LOCK_REQ，无法按锁定版本安装。生成: scripts/dev.sh lock-backend"
  ensure_venv

  local stamp="$VENV_DIR/.install-stamp"
  local need_install=0
  if [ "${FORCE_PIP:-0}" = "1" ]; then need_install=1
  elif [ ! -f "$stamp" ]; then need_install=1
  elif [ "$LOCK_REQ" -nt "$stamp" ]; then need_install=1; fi

  if [ "$need_install" = "1" ]; then
    info "pip install -r requirements.lock.txt"
    run_logged "$SETUP_LOG" "$VENV_DIR/bin/pip" install -r "$LOCK_REQ"
    touch "$stamp"
    ok "后端依赖安装完成（$(venv_pip freeze | wc -l) 个包）"
  else
    ok "后端依赖与锁文件一致，跳过安装（锁文件未变动；FORCE_PIP=1 可强制重装）"
  fi
}

# ---- 前端 npm ----
install_frontend() {
  step "2/4 · 前端" "安装前端依赖（package-lock.json，npm 缓存: $NPM_CONFIG_CACHE）"
  local lockfile="$FRONTEND_DIR/package-lock.json"
  [ -f "$lockfile" ] || die "缺少 $lockfile，无法按锁定版本安装。生成: scripts/dev.sh lock-frontend"

  local need_install=0
  if [ "${FORCE_NPM:-0}" = "1" ]; then need_install=1
  elif [ ! -d "$FRONTEND_DIR/node_modules" ]; then need_install=1
  elif [ "$lockfile" -nt "$FRONTEND_DIR/node_modules" ]; then need_install=1; fi

  if [ "$need_install" = "1" ]; then
    # npm ci 严格按锁文件安装，先清除跨平台/残留的 node_modules，避免上次中间产物干扰
    info "清理残留 node_modules，执行 npm ci（严格按锁版本）"
    rm -rf "$FRONTEND_DIR/node_modules"
    (cd "$FRONTEND_DIR" && run_logged "$SETUP_LOG" npm ci --no-audit --no-fund)
    ok "前端依赖安装完成"
  else
    ok "前端依赖与锁文件一致，跳过安装（FORCE_NPM=1 可强制重装）"
  fi
}

setup_deps() {
  : > "$SETUP_LOG"
  install_backend
  install_frontend
}

# ============================================================================
# 步骤 3：统一构建检查（启动与 CI 共用这一道关，类型问题在此暴露）
# ============================================================================
clean_build_outputs() {
  # 只清中间产物，不动依赖和安装缓存
  rm -rf "$FRONTEND_DIR/dist"
  find "$FRONTEND_DIR" -maxdepth 2 -name '*.tsbuildinfo' -not -path '*/node_modules/*' -delete 2>/dev/null || true
  find "$BACKEND_DIR" -type d -name '__pycache__' -not -path '*/.venv/*' -exec rm -rf {} + 2>/dev/null || true
}

check_backend() {
  step "3/4 · 后端" "构建检查：字节码编译 + 应用导入"
  (cd "$BACKEND_DIR" && run_logged "$CHECK_LOG" "$VENV_DIR/bin/python" -m compileall -q app)
  (cd "$BACKEND_DIR" && run_logged "$CHECK_LOG" "$VENV_DIR/bin/python" -c 'from app.main import app; print("FastAPI app import OK")')
  ok "后端检查通过"
}

check_frontend() {
  step "3/4 · 前端" "构建检查：vue-tsc 类型检查 + vite build"
  # package.json 中 build = "vue-tsc && vite build"，直接复用，保证本地与本脚本走同一道检查
  (cd "$FRONTEND_DIR" && run_logged "$CHECK_LOG" npm run build)
  [ -f "$FRONTEND_DIR/dist/index.html" ] || die "构建未产出 dist/index.html" "$CHECK_LOG"
  ok "前端类型检查与构建通过 -> frontend/dist"
}

run_check() {
  : > "$CHECK_LOG"
  clean_build_outputs
  check_backend
  check_frontend
  echo
  ok "构建检查全部通过"
}

# ============================================================================
# 步骤 4：启动（运行方式与原来保持一致：uvicorn + vite dev）
# ============================================================================
_started_pids=()
start_service() {
  local name="$1" pidfile="$2" logfile="$3" workdir="$4"; shift 4
  if [ -f "$pidfile" ] && _pid_alive "$(cat "$pidfile")"; then
    ok "$name 已在运行(pid $(cat "$pidfile"))，跳过"
    return
  fi
  info "启动 $name ... 日志: $logfile"
  # 独立进程组，便于 stop 时连同 uvicorn/vite 派生子进程一起回收
  # setsid exec 后即后台作业本体，$! 就是新进程组组长 PID
  pushd "$workdir" >/dev/null
  setsid "$@" >>"$logfile" 2>&1 &
  local pid=$!
  popd >/dev/null
  echo "$pid" >"$pidfile"
  _started_pids+=("$pid")
}

wait_http() {
  local url="$1" pid="$2" logfile="$3" name="$4" tries="${5:-60}" i
  for ((i=1; i<=tries; i++)); do
    if ! _pid_alive "$pid"; then
      die "$name 进程已提前退出(见日志末尾)" "$logfile"
    fi
    if curl -fsS -o /dev/null --max-time 2 "$url" 2>/dev/null; then
      return 0
    fi
    sleep 0.5
  done
  die "$name 在 ${tries} 次探测后仍未就绪: $url" "$logfile"
}

start_all() {
  : > "$BE_LOG"; : > "$FE_LOG"

  step "4/4" "启动工作流引擎（与原手动启动方式一致）"
  check_start_ports
  local reload_opt=()
  [ "${BACKEND_RELOAD:-0}" = "1" ] && reload_opt=(--reload)

  start_service "后端(uvicorn)" "$BE_PIDFILE" "$BE_LOG" "$BACKEND_DIR" \
    "$VENV_DIR/bin/python" -m uvicorn app.main:app --host 0.0.0.0 --port "$BACKEND_PORT" "${reload_opt[@]}"
  start_service "前端(vite)" "$FE_PIDFILE" "$FE_LOG" "$FRONTEND_DIR" \
    npm run dev -- --port "$FRONTEND_PORT" --host

  local be_pid fe_pid
  be_pid="$(cat "$BE_PIDFILE")"; fe_pid="$(cat "$FE_PIDFILE")"

  wait_http "http://127.0.0.1:$BACKEND_PORT/docs" "$be_pid" "$BE_LOG" "后端" 60
  ok "后端就绪: http://localhost:$BACKEND_PORT  (API 文档 /docs, WebSocket /ws)"
  wait_http "http://127.0.0.1:$FRONTEND_PORT/" "$fe_pid" "$FE_LOG" "前端" 60
  ok "前端就绪: http://localhost:$FRONTEND_PORT  (代理 /api、/ws -> :$BACKEND_PORT)"

  echo
  echo "${C_OK}════════════════════════════════════════════════════${C_RST}"
  echo "${C_OK} 工作流引擎已启动，浏览器打开: http://localhost:$FRONTEND_PORT ${C_RST}"
  echo " 停止: scripts/dev.sh stop    日志: scripts/dev.sh logs    状态: scripts/dev.sh status"
  echo "${C_OK}════════════════════════════════════════════════════${C_RST}"
}

stop_all() {
  local stopped=0
  for pair in "BE:$BE_PIDFILE" "FE:$FE_PIDFILE"; do
    local name="${pair%%:*}" pf="${pair#*:}"
    [ -f "$pf" ] || continue
    local pid; pid="$(cat "$pf" 2>/dev/null || true)"
    if [ -n "$pid" ] && _pid_alive "$pid"; then
      info "停止 $name (进程组 $pid) ..."
      # 杀掉整个进程组（组 ID == 组长 PID 的绝对值取负），回收 uvicorn/vite 子进程
      kill -- "-$pid" 2>/dev/null || kill "$pid" 2>/dev/null || true
      for _ in $(seq 1 20); do _pid_alive "$pid" || break; sleep 0.25; done
      _pid_alive "$pid" && { kill -9 -- "-$pid" 2>/dev/null || kill -9 "$pid" 2>/dev/null || true; }
      stopped=1
    fi
    rm -f "$pf"
  done
  if [ "$stopped" = "1" ]; then ok "已停止"; else info "没有正在运行的服务"; fi
  # 兜底提示：端口仍被占用时说明不是本脚本启动的进程
  for p in "$BACKEND_PORT:$BE_PIDFILE" "$FRONTEND_PORT:$FE_PIDFILE"; do
    local port="${p%%:*}"
    if ! port_free "$port"; then
      warn "端口 $port 仍被占用，占用方: $(port_owner_hint "$port")"
    fi
  done
}

status_all() {
  local be="未运行" fe="未运行"
  if [ -f "$BE_PIDFILE" ] && _pid_alive "$(cat "$BE_PIDFILE")"; then be="运行中 pid $(cat "$BE_PIDFILE")"; fi
  if [ -f "$FE_PIDFILE" ] && _pid_alive "$(cat "$FE_PIDFILE")"; then fe="运行中 pid $(cat "$FE_PIDFILE")"; fi
  echo "后端 :$BACKEND_PORT  $be"
  echo "前端 :$FRONTEND_PORT  $fe"
  echo "运行时目录: $RUN_DIR (日志、pid 文件)"
}

# ============================================================================
# clean：清中间产物，重跑不带上次残留（依赖目录与安装缓存保留以复用）
# ============================================================================
do_clean() {
  step "clean" "清理中间产物（保留 node_modules / .venv / .cache 安装缓存）"
  # 先停止可能在跑的服务，避免 dist 被占用
  stop_all
  clean_build_outputs
  rm -rf "$FRONTEND_DIR/node_modules/.vite" "$FRONTEND_DIR/node_modules/.tmp"
  rm -f "$VENV_DIR/.install-stamp"
  rm -f "$BE_PIDFILE" "$FE_PIDFILE" "$BE_LOG" "$FE_LOG" "$SETUP_LOG" "$CHECK_LOG"
  ok "已清理构建产物与运行时文件；下次运行会复用锁文件与安装缓存快速重装校验"
  info "如需连依赖一并重装: rm -rf frontend/node_modules backend/.venv（或 FORCE_NPM=1 FORCE_PIP=1）"
  info "如需连安装缓存也清空: rm -rf .cache"
}

# ============================================================================
# 锁文件重新生成
# ============================================================================
lock_frontend() {
  step "lock" "重新生成前端 package-lock.json（依据 package.json 解析）"
  (cd "$FRONTEND_DIR" && run_logged "$SETUP_LOG" npm install --package-lock-only --no-audit --no-fund)
  ok "已更新 $FRONTEND_DIR/package-lock.json；请提交并让其他人重新 scripts/dev.sh setup"
}

lock_backend() {
  step "lock" "重新生成后端 requirements.lock.txt（全量传递依赖）"
  : > "$SETUP_LOG"
  local tmpvenv="$RUN_DIR/lock-venv"
  rm -rf "$tmpvenv"
  python3 -m venv "$tmpvenv" >>"$SETUP_LOG" 2>&1 || {
    python3 -m venv --without-pip "$tmpvenv" >>"$SETUP_LOG" 2>&1 || die "无法创建临时虚拟环境" "$SETUP_LOG"
    local getpip="$CACHE_DIR/get-pip.py"
    [ -s "$getpip" ] || curl -fsSL https://bootstrap.pypa.io/get-pip.py -o "$getpip" 2>>"$SETUP_LOG"
    "$tmpvenv/bin/python" "$getpip" >>"$SETUP_LOG" 2>&1 || die "pip 引导失败" "$SETUP_LOG"
  }
  "$tmpvenv/bin/pip" install -r "$SRC_REQ" >>"$SETUP_LOG" 2>&1 || die "依赖安装失败" "$SETUP_LOG"
  {
    echo "# 由 requirements.txt 全量解析生成（含传递依赖），用于复现安装。"
    echo "# 重新生成：scripts/dev.sh lock-backend（或 pip install -r requirements.txt 后 pip freeze）。"
    echo "# 仅锁定版本不锁定 wheel hash，以同时兼容 Linux/macOS 与 arm64/x86_64；pip 按当前平台选择 wheel。"
    "$tmpvenv/bin/pip" freeze
  } > "$LOCK_REQ"
  rm -rf "$tmpvenv"
  ok "已更新 $LOCK_REQ；请提交并让其他人重新 scripts/dev.sh setup"
}

# ============================================================================
# 入口
# ============================================================================
usage() { sed -n '2,30p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

main() {
  local cmd="${1:-all}"
  case "$cmd" in
    all|setup|check|start)
      preflight
      setup_deps
      run_check
      if [ "$cmd" = "setup" ] || [ "$cmd" = "check" ]; then
        echo; ok "完成: $cmd"
      fi
      if [ "$cmd" = "all" ] || [ "$cmd" = "start" ]; then
        start_all
      fi
      ;;
    stop)   stop_all ;;
    status) status_all ;;
    logs)
      case "${2:-}" in
        be|backend)  tail -n 100 -f "$BE_LOG" ;;
        fe|frontend) tail -n 100 -f "$FE_LOG" ;;
        *) echo "===== backend.log ====="; tail -n 40 "$BE_LOG" 2>/dev/null
           echo "===== frontend.log ====="; tail -n 40 "$FE_LOG" 2>/dev/null ;;
      esac
      ;;
    clean) do_clean ;;
    lock-frontend) lock_frontend ;;
    lock-backend)  lock_backend ;;
    -h|--help|help) usage ;;
    *) err "未知命令: $cmd"; echo; usage; exit 2 ;;
  esac
}
main "$@"
