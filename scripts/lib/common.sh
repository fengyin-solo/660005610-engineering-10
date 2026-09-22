#!/usr/bin/env bash
# 公共函数库：统一的步骤输出、错误定位与清理工具。
# 被 scripts/ 下的其他脚本 source 使用，不单独执行。

# 任一条命令失败即退出；引用未定义变量报错；管道中任一环节失败即失败。
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CACHE_DIR="$ROOT_DIR/.dev-cache"
LOG_DIR="$ROOT_DIR/logs/run"
FRONTEND_DIR="$ROOT_DIR/frontend"
BACKEND_DIR="$ROOT_DIR/backend"
VENV_DIR="$BACKEND_DIR/.venv"

# 对外服务端口（与原启动方式保持一致：后端 8000，前端 vite 3000）
BACKEND_PORT=8000
FRONTEND_PORT=3000

mkdir -p "$CACHE_DIR" "$LOG_DIR"

# ---- 带步骤名的输出：任何一步失败时，最后看到的步骤标题就是卡住的位置 ----
_current_step=""
_step_start=0

step() {
  _current_step="$1"
  _step_start=$(date +%s)
  printf '\n\033[1;36m==> [%s] %s\033[0m\n' "$(date +%H:%M:%S)" "$_current_step"
}

info()  { printf '    \033[0;36m· %s\033[0m\n' "$*"; }
ok()    {
  local elapsed=$(( $(date +%s) - _step_start ))
  printf '    \033[0;32m✓ %s (%ss)\033[0m\n' "$*" "$elapsed"
}
warn()  { printf '    \033[0;33m! %s\033[0m\n' "$*" >&2; }
die()   { printf '\n\033[1;31m✗ 失败步骤: %s\033[0m\n' "${_current_step:-<未命名步骤>}" >&2; printf '  \033[1;31m原因: %s\033[0m\n' "$*" >&2; exit 1; }

# 命令执行失败时统一走 die，打印失败的步骤与具体命令
trap 'die "命令执行失败（退出码 $?）: ${BASH_COMMAND}"' ERR

# ---- 删除目录：容器内 overlayfs 偶发首次删除残留导致 "Directory not empty"，做一次重试 ----
rm_retry() {
  local target="$1"
  [ -e "$target" ] || return 0
  rm -rf -- "$target" 2>/dev/null || true
  if [ -e "$target" ]; then
    sleep 0.3
    rm -rf -- "$target" 2>/dev/null || true
  fi
  [ ! -e "$target" ] || die "无法清理 $target，请检查是否有进程占用后手动删除"
}

# ---- 计算锁文件指纹：锁文件没变就复用已安装依赖（缓存可复用） ----
fingerprint() {
  local files=("$@")
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "${files[@]}" | awk '{print $1}' | sha256sum | awk '{print $1}'
  else
    shasum -a 256 "${files[@]}" | awk '{print $1}' | shasum -a 256 | awk '{print $1}'
  fi
}

fingerprint_matches() {
  local stamp_file="$1"; shift
  [ -f "$stamp_file" ] || return 1
  [ "$(cat "$stamp_file")" = "$(fingerprint "$@")" ]
}
