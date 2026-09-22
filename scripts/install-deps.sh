#!/usr/bin/env bash
# 按锁定版本安装前后端依赖。
#   - 前端：package-lock.json 锁定，npm ci 严格按锁文件安装（漂移即失败）
#   - 后端：requirements.lock 锁定全部传递依赖，pip install -r 精确安装
#   - 缓存复用：全局 npm/pip 缓存不动；锁文件指纹未变且已装好时直接跳过
#   - 指纹变化时：删掉旧的依赖目录再装，避免新旧包混装产生中间残留
set -Eeuo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

# ---------- 前端 ----------
install_frontend() {
  step "安装前端依赖（npm ci，按 package-lock.json 锁定版本）"

  local stamp="$CACHE_DIR/frontend.fingerprint"
  local lock="$FRONTEND_DIR/package-lock.json"
  local pkg="$FRONTEND_DIR/package.json"

  [ -f "$lock" ] || die "缺少 frontend/package-lock.json。请在 frontend/ 执行 npm install 生成并提交，不要凭 node_modules 口口相传"

  if [ -d "$FRONTEND_DIR/node_modules" ] && fingerprint_matches "$stamp" "$lock" "$pkg"; then
    info "锁文件未变化，复用现有 node_modules（需要强制重装可执行 make clean-deps）"
  else
    if [ -d "$FRONTEND_DIR/node_modules" ]; then
      info "检测到锁文件变化或未完成的安装，清理旧 node_modules ..."
      rm_retry "$FRONTEND_DIR/node_modules"
    fi
    # --prefer-offline：优先用本地 npm 缓存（缓存可复用），缺失再走网络
    if ! ( cd "$FRONTEND_DIR" && npm ci --prefer-offline --no-audit --no-fund ); then
      die "npm ci 失败。常见原因：① 网络无法访问 registry（检查代理/网络）；② package.json 与锁文件不一致（在 frontend/ 执行 npm install 更新锁文件后重试）"
    fi
    fingerprint "$lock" "$pkg" > "$stamp"
  fi
  ok "前端依赖就绪"
}

# ---------- 后端 ----------
ensure_venv_python() {
  # 优先使用常规 venv；系统缺 ensurepip 时退回 --without-pip + get-pip.py
  if python3 -m venv "$VENV_DIR" >/dev/null 2>&1 && "$VENV_DIR/bin/python" -m pip --version >/dev/null 2>&1; then
    return 0
  fi
  info "系统 venv 未自带 pip，改用 get-pip.py 引导（结果与正常 venv 一致）..."
  rm_retry "$VENV_DIR"
  python3 -m venv --without-pip "$VENV_DIR"
  local get_pip="$CACHE_DIR/get-pip.py"
  if [ ! -f "$get_pip" ]; then
    if ! curl -fsSL https://bootstrap.pypa.io/get-pip.py -o "$get_pip"; then
      die "下载 get-pip.py 失败：网络无法访问 https://bootstrap.pypa.io，请检查网络/代理后重试"
    fi
  fi
  "$VENV_DIR/bin/python" "$get_pip" --quiet \
    || die "get-pip.py 引导 pip 失败"
}

install_backend() {
  step "安装后端依赖（pip install -r requirements.lock 全量锁定版本）"

  local stamp="$CACHE_DIR/backend.fingerprint"
  local lock="$BACKEND_DIR/requirements.lock"

  [ -f "$lock" ] || die "缺少 backend/requirements.lock。请在可用环境执行 backend/.venv/bin/pip freeze > backend/requirements.lock 后提交"

  if [ -x "$VENV_DIR/bin/python" ] && fingerprint_matches "$stamp" "$lock"; then
    info "锁文件未变化，复用现有 .venv（需要强制重建可执行 make clean-deps）"
    return 0
  fi

  if [ -d "$VENV_DIR" ] && [ ! -x "$VENV_DIR/bin/python" ]; then
    warn "现有 .venv 不完整（可能是从其他机器拷贝的残留），删除重建"
    rm_retry "$VENV_DIR"
  fi

  if [ ! -x "$VENV_DIR/bin/python" ]; then
    ensure_venv_python
  fi

  # 项目内 pip 缓存目录，删除依赖目录不会清掉下载缓存，重跑/换机均可复用
  if ! "$VENV_DIR/bin/python" -m pip install \
        --require-virtualenv \
        --cache-dir "$CACHE_DIR/pip" \
        -r "$lock"; then
    die "后端依赖安装失败。常见原因：网络无法访问 PyPI（检查代理），或 requirements.lock 与当前平台不兼容（numpy/pydantic-core 含平台相关 wheel，换平台后需重新生成锁文件）"
  fi

  fingerprint "$lock" > "$stamp"
  ok "后端依赖就绪（解释器 $("$VENV_DIR/bin/python" --version 2>&1)）"
}

install_frontend
install_backend

ok "全部依赖已按锁定版本安装完成"
