#!/usr/bin/env bash
# 统一构建检查（启动流程也复用本脚本作为前置关卡）：
#   1. 清理上一次构建的中间产物，保证每次都是干净构建，不残留上次结果；
#   2. 后端：语法编译 + 应用导入检查（import 期错误立即暴露）；
#   3. 前端：vue-tsc 类型检查 + vite 生产打包。
# 任何一步不过立即停止并指出失败步骤；类型问题在这里暴露，不必等到联调。
set -Eeuo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

# ---------- 清理旧产物（构建前固定执行，重跑不吃到上次的中间结果） ----------
step "清理上次构建产物"
rm_retry "$FRONTEND_DIR/dist"
rm_retry "$BACKEND_DIR/app/__pycache__"
# 清理 vue-tsc 旧版本可能遗留在 src 里的 emit 副产品（*.vue.js / 同名 .js）
find "$FRONTEND_DIR/src" -type f \( -name '*.vue.js' -o -name '*__VLS_*' \) -delete 2>/dev/null || true
info "已清理 frontend/dist、backend/app/__pycache__、遗留的 vue-tsc 副产品"
ok "工作区干净"

# ---------- 后端检查 ----------
step "构建检查 1/2：后端（字节码编译 + 应用导入）"
[ -x "$VENV_DIR/bin/python" ] || die "后端虚拟环境不存在，请先执行 make install"
if ! "$VENV_DIR/bin/python" -m py_compile "$BACKEND_DIR/app/"*.py; then
  die "后端存在语法错误（py_compile 未通过），见上方报错文件与行号"
fi
if ! ( cd "$BACKEND_DIR" && ./.venv/bin/python -c "from app.main import app" ); then
  die "后端应用导入失败（app.main:app），通常是依赖缺失/初始化报错，见上方堆栈"
fi
ok "后端编译与导入检查通过"

# ---------- 前端检查 ----------
step "构建检查 2/2：前端（vue-tsc 类型检查 + vite build）"
[ -d "$FRONTEND_DIR/node_modules" ] || die "前端依赖未安装，请先执行 make install"
if ! ( cd "$FRONTEND_DIR" && npm run build ); then
  die "前端构建失败。若上方是 TS 类型报错请修复类型问题；若是打包报错请查看对应模块"
fi
[ -f "$FRONTEND_DIR/dist/index.html" ] || die "构建未产出 dist/index.html，vite 构建可能异常中断"
ok "前端类型检查与生产打包通过（产物在 frontend/dist）"

ok "统一构建检查全部通过"
