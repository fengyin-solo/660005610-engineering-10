# 分布式任务工作流DAG编排与执行引擎

基于Vue 3 + FastAPI的任务编排平台，DAG拓扑排序、任务状态机、多Worker并发池、执行甘特图。

## 目标用户
数据工程师、ETL/ML Pipeline开发者、技术架构师

## 技术栈
- 前端: Vue 3 + TypeScript + Vite + Pinia + Element Plus + ECharts
- 后端: Python FastAPI + NumPy + SQLite + WebSocket

## 核心功能
1. DAG工作流编辑器：拖拽添加任务节点、连线建立依赖关系、BFS拓扑排序验证环检测
2. Spring StateMachine风格任务状态机：PENDING→RUNNING→SUCCESS/FAILED/TIMEOUT
3. 多Worker并发池模拟：可配置Worker数量、任务执行耗时模拟(指数分布)
4. 任务编排策略：FIFO/优先级/最大并发三种调度策略
5. 重试机制：可配置最大重试次数、指数退避延迟
6. 执行监控：ECharts甘特图时间线渲染、实时WebSocket推送任务状态
7. 熔断保护：连续失败阈值触发熔断，冷却时间后自动恢复

## 本地开发（一条命令跑通）

所有环节统一走 `scripts/dev.sh`，启动和构建检查共用同一套步骤，不再需要口口相传：

```bash
scripts/dev.sh            # 预检 → 按锁文件装依赖 → 构建检查 → 启动（推荐）
# 或分步执行
scripts/dev.sh setup      # 预检 + 安装依赖
scripts/dev.sh check      # 统一构建检查（前端 vue-tsc 类型检查 + vite build；后端编译 + 导入）
scripts/dev.sh start      # setup + check 后启动，等价于直接运行
scripts/dev.sh stop       # 停止服务
scripts/dev.sh status     # 查看前后端运行状态
scripts/dev.sh logs [fe|be]   # 查看日志
scripts/dev.sh clean      # 清理构建产物/运行时文件（保留依赖与安装缓存，修好后可直接重跑）
```

启动后访问 http://localhost:3000 （后端 http://localhost:8000，API 文档 http://localhost:8000/docs）。

### 环境要求
- Node.js 18+（推荐 20 LTS）、npm
- Python 3.9+（脚本自动创建 `backend/.venv`；Debian/Ubuntu 缺 `python3-venv` 时会用 `get-pip.py` 自动引导）
- bash

### 依赖锁定（保证不同机器装出一致结果）
- 前端：`frontend/package-lock.json`，一律 `npm ci` 严格按锁版本安装（升级依赖后提交锁文件）
- 后端：`backend/requirements.lock.txt`（全量传递依赖），`pip install -r requirements.lock.txt`
- 两者的安装缓存都放在仓库内 `.cache/`（npm、pip），可离线复用、加速重装；该目录不入库
- 修改 `package.json` 后执行 `scripts/dev.sh lock-frontend`；修改 `requirements.txt` 后执行 `scripts/dev.sh lock-backend`，然后提交锁文件

### 运行方式（与原先一致，未做改变）
- 后端仍是 `uvicorn app.main:app --port 8000`（在 `backend/` 下，可选 `BACKEND_RELOAD=1` 热重载）
- 前端仍是 `vite` 开发服务器（:3000，代理 `/api`、`/ws` 到 :8000）

### 常用环境变量
- `FRONTEND_PORT=3000` / `BACKEND_PORT=8000`：端口被占用时可改端口（脚本启动前会预检并提示占用方）
- `FORCE_NPM=1` / `FORCE_PIP=1`：强制重装依赖
- `BACKEND_RELOAD=1`：uvicorn 热重载

### 失败定位
任何一步失败都会打印：卡在第几步、失败命令与退出码、日志末尾 40 行、完整日志路径（`.dev/*.log`）。
修好后重新执行同一命令即可；如需从干净状态重跑，先 `scripts/dev.sh clean`。
