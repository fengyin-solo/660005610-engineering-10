#!/usr/bin/env bash
# 本地开发一键启动。与 make build 走同一条前置流程：
#   预检 → 按锁文件装依赖（已装且锁未变则复用缓存）→ 统一构建检查 → 启动服务
# 服务的运行方式与原先完全一致，没有包一层框架：
#   后端: uvicorn app.main:app --reload --port 8000
#   前端: vite（dev server，端口 3000，/api、/ws 代理到 8000）
set -Eeuo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

SCRIPTS_DIR="$(dirname "${BASH_SOURCE[0]}")"

# 与“构建”走同一条流程：预检 + 依赖 + 统一构建检查
"$SCRIPTS_DIR/preflight.sh"
"$SCRIPTS_DIR/install-deps.sh"
"$SCRIPTS_DIR/build.sh"

BACKEND_LOG="$LOG_DIR/backend.log"
FRONTEND_LOG="$LOG_DIR/frontend.log"
BACKEND_PIDFILE="$LOG_DIR/backend.pid"
FRONTEND_PIDFILE="$LOG_DIR/frontend.pid"

PIDS=()
cleanup() {
  printf '\n\033[1;33m==> 停止开发服务 ...\033[0m\n'
  for pid in "${PIDS[@]:-}"; do
    [ -n "$pid" ] && kill "$pid" 2>/dev/null || true
  done
  # 收尾自己启动出来的子进程（uvicorn --reload 会派生 reloader 子进程）
  pkill -f "uvicorn app.main:app --reload" 2>/dev/null || true
  pkill -f "$FRONTEND_DIR/node_modules/.bin/vite" 2>/dev/null || true
  rm -f "$BACKEND_PIDFILE" "$FRONTEND_PIDFILE"
}
trap cleanup EXIT INT TERM

step "启动后端服务（uvicorn :${BACKEND_PORT}，热重载）"
: > "$BACKEND_LOG"
(
  cd "$BACKEND_DIR"
  exec ./.venv/bin/python -m uvicorn app.main:app \
    --reload --host 0.0.0.0 --port "$BACKEND_PORT"
) > >(sed -u 's/\r$//;s/^/[backend] /' | tee "$BACKEND_LOG" >/dev/null) 2>&1 &
BACKEND_PID=$!
PIDS+=("$BACKEND_PID")
echo "$BACKEND_PID" > "$BACKEND_PIDFILE"

# 等后端真正起来（轮询健康端口），避免前端先起、代理打到空端口
for i in $(seq 1 60); do
  if "$VENV_DIR/bin/python" - "$BACKEND_PORT" <<'PY' 2>/dev/null; then
import socket, sys
s = socket.socket()
s.settimeout(0.5)
try:
    s.connect(("127.0.0.1", int(sys.argv[1])))
except OSError:
    sys.exit(1)
else:
    sys.exit(0)
finally:
    s.close()
PY
    break
  fi
  if ! kill -0 "$BACKEND_PID" 2>/dev/null; then
    die "后端进程已退出，未能监听 ${BACKEND_PORT}。完整日志见 ${BACKEND_LOG}"
  fi
  sleep 0.5
done
"$VENV_DIR/bin/python" - "$BACKEND_PORT" <<'PY' 2>/dev/null || { exit 1; }
import socket, sys
s = socket.socket(); s.settimeout(0.5)
try: s.connect(("127.0.0.1", int(sys.argv[1])))
except OSError: sys.exit(1)
else: sys.exit(0)
finally: s.close()
PY
ok "后端已就绪 http://localhost:${BACKEND_PORT}（API 文档 /docs）"

step "启动前端服务（vite :${FRONTEND_PORT}，/api、/ws 代理到后端）"
: > "$FRONTEND_LOG"
(
  cd "$FRONTEND_DIR"
  exec npm run dev -- --host 0.0.0.0
) > >(sed -u 's/\r$//;s/^/[frontend] /' | tee "$FRONTEND_LOG" >/dev/null) 2>&1 &
FRONTEND_PID=$!
PIDS+=("$FRONTEND_PID")
echo "$FRONTEND_PID" > "$FRONTEND_PIDFILE"

# 等 vite 监听端口
for i in $(seq 1 60); do
  if python3 - "$FRONTEND_PORT" <<'PY' 2>/dev/null; then
import socket, sys
s = socket.socket(); s.settimeout(0.5)
try: s.connect(("127.0.0.1", int(sys.argv[1])))
except OSError: sys.exit(1)
else: sys.exit(0)
finally: s.close()
PY
    break
  fi
  if ! kill -0 "$FRONTEND_PID" 2>/dev/null; then
    die "前端进程已退出，未能监听 ${FRONTEND_PORT}。完整日志见 ${FRONTEND_LOG}"
  fi
  sleep 0.5
done
python3 - "$FRONTEND_PORT" <<'PY' 2>/dev/null || die "前端在 30 秒内未监听 ${FRONTEND_PORT}，见 ${FRONTEND_LOG}"
import socket, sys
s = socket.socket(); s.settimeout(0.5)
try: s.connect(("127.0.0.1", int(sys.argv[1])))
except OSError: sys.exit(1)
else: sys.exit(0)
finally: s.close()
PY
ok "前端已就绪 http://localhost:${FRONTEND_PORT}"

cat <<EOF

\033[1;32m========================================================
 开发环境已启动（与构建共用同一流程，检查全部通过）
   前端:  http://localhost:${FRONTEND_PORT}
   后端:  http://localhost:${BACKEND_PORT}  (文档 /docs)
 日志:  ${BACKEND_LOG}
        ${FRONTEND_LOG}
 按 Ctrl+C 停止两个服务（会自动清理子进程）
========================================================\033[0m
EOF

# 任一服务退出即整体退出并指出是谁挂了（轮询方式，兼容 bash 3.2 / macOS 自带 bash）
while true; do
  if ! kill -0 "$BACKEND_PID" 2>/dev/null; then
    die "后端服务异常退出，见上方输出或 ${BACKEND_LOG}"
  fi
  if ! kill -0 "$FRONTEND_PID" 2>/dev/null; then
    die "前端服务异常退出，见上方输出或 ${FRONTEND_LOG}"
  fi
  sleep 1
done
