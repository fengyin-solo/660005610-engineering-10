#!/usr/bin/env bash
# 启动/构建前的环境预检：
#   1. Node.js / Python 是否存在、版本是否满足要求；
#   2. 后端 8000 / 前端 3000 端口是否已被占用，占用时指出是谁、怎么处理。
set -Eeuo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

# 最低版本要求（按当前锁定依赖的实际要求设定）
NODE_MAJOR_MIN=18
PYTHON_MINOR_MIN=10   # 需要 python3 >= 3.10

version_major() { printf '%s' "$1" | cut -d. -f1; }
version_minor() { printf '%s' "$1" | cut -d. -f2; }

step "预检 1/2：工具链"

if ! command -v node >/dev/null 2>&1; then
  die "未找到 node（需要 Node.js >= ${NODE_MAJOR_MIN}）。请安装后重试：https://nodejs.org/"
fi
NODE_VERSION="$(node --version | tr -d 'v')"
if [ "$(version_major "$NODE_VERSION")" -lt "$NODE_MAJOR_MIN" ]; then
  die "Node.js 版本为 ${NODE_VERSION}，需要 >= ${NODE_MAJOR_MIN}（建议使用 20 LTS）"
fi
info "Node.js ${NODE_VERSION}（npm $(npm --version)）✓"

if ! command -v python3 >/dev/null 2>&1; then
  die "未找到 python3（需要 Python >= 3.${PYTHON_MINOR_MIN}）。请安装后重试。"
fi
PY_VERSION="$(python3 -c 'import sys;print("%d.%d"%sys.version_info[:2])')"
if [ "$(version_minor "$PY_VERSION")" -lt "$PYTHON_MINOR_MIN" ]; then
  die "Python 版本为 ${PY_VERSION}，需要 >= 3.${PYTHON_MINOR_MIN}"
fi
info "Python ${PY_VERSION} ✓（venv 若缺 pip，安装阶段会自动通过 get-pip.py 引导）"

command -v curl >/dev/null 2>&1 || die "未找到 curl，安装依赖引导阶段需要它"

step "预检 2/2：端口占用"

# 用 python 探测端口占用并尝试给出占用方 PID/命令（不依赖 ss/lsof）
PORT_REPORT="$(python3 - "$BACKEND_PORT" "$FRONTEND_PORT" <<'PY' || true
import os, sys, subprocess
ports = [int(p) for p in sys.argv[1:]]
occupied = []
for port in ports:
    pid = None
    # /proc/net/tcp* 查找 LISTEN 状态的端口
    hexport = "%04X" % port
    inodes = set()
    for table in ("/proc/net/tcp", "/proc/net/tcp6"):
        try:
            with open(table) as f:
                next(f)
                for line in f:
                    parts = line.split()
                    local, state, inode = parts[1], parts[3], parts[9]
                    if local.split(":")[1] == hexport and state == "0A":
                        inodes.add(inode)
        except FileNotFoundError:
            pass
    if inodes:
        for pid_dir in os.listdir("/proc"):
            if not pid_dir.isdigit():
                continue
            fd_dir = f"/proc/{pid_dir}/fd"
            try:
                for fd in os.listdir(fd_dir):
                    try:
                        target = os.readlink(f"{fd_dir}/{fd}")
                    except OSError:
                        continue
                    if target.startswith("socket:[") and target[8:-1] in inodes:
                        pid = int(pid_dir)
                        break
            except (FileNotFoundError, PermissionError):
                continue
            if pid:
                break
        occupied.append((port, pid))
for port, pid in occupied:
    cmd = ""
    if pid:
        try:
            with open(f"/proc/{pid}/cmdline", "rb") as f:
                cmd = f.read().replace(b"\0", b" ").decode().strip()
        except OSError:
            pass
    print(f"{port} {pid or '-'} {cmd}")
PY
)"

PORT_BUSY=0
while IFS=' ' read -r port pid cmd; do
  [ -n "${port:-}" ] || continue
  PORT_BUSY=1
  who="未知进程"
  [ "$pid" != "-" ] && who="PID ${pid}：${cmd:-（无权限读取命令行）}"
  warn "端口 ${port} 已被占用 —— ${who}"
done <<< "$PORT_REPORT"

if [ "$PORT_BUSY" -ne 0 ]; then
  cat >&2 <<EOF

  端口被占用会导致服务起不来或起错对象。处理方式（二选一）：
    1) 停掉占用进程后重跑：kill <PID>
    2) 如果是上次异常退出遗留的本项目服务：
         后端: kill \$(cat logs/run/backend.pid)   （或 pkill -f 'uvicorn app.main')
         前端: kill \$(cat logs/run/frontend.pid)  （或 pkill -f 'vite')
  本流程不会替你强杀进程，请确认后再操作。
EOF
  die "存在被占用的端口（后端 ${BACKEND_PORT} / 前端 ${FRONTEND_PORT}）"
fi
info "端口 ${BACKEND_PORT}（后端）、${FRONTEND_PORT}（前端）空闲 ✓"

ok "预检通过"
