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

---

## 本地开发（统一流程，一条命令跑通）

### 前置要求

| 工具 | 要求 | 说明 |
| --- | --- | --- |
| Node.js | >= 18（建议 20 LTS） | 前端构建与 dev server |
| Python | >= 3.10（开发环境为 3.11） | 后端运行环境；无需预装 pip，脚本会在缺失时自动用 get-pip.py 引导 |
| make | 任意版本 | macOS 自带；Windows 可用 WSL |
| curl | - | 引导 pip / 健康检查使用 |

### 开始

```bash
make dev
```

这一条命令会依次跑完下面整条流程，**启动和 `make build` 构建走的是同一条流程**：

1. **预检**：检查 Node/Python 版本；检查 8000 / 3000 端口是否被占用（被占用会直接指出占用进程的 PID 和命令行，不强杀）
2. **安装依赖（按锁定版本）**：
   - 前端 `npm ci`，严格按 `frontend/package-lock.json` 安装，版本漂移会直接失败
   - 后端在 `backend/.venv` 中按 `backend/requirements.lock` 安装（含全部传递依赖）
   - 锁文件没变且依赖已装好时自动跳过；npm/pip 下载缓存（`.dev-cache/`）跨重跑复用
3. **统一构建检查**：先清掉上次的构建产物，再做后端字节码编译 + 应用导入检查、前端 `vue-tsc` 类型检查 + `vite build` 打包。类型问题在这里就暴露，不用等到联调
4. **启动服务**（运行方式与原来完全一致，没有额外封装）：
   - 后端 `uvicorn app.main:app --reload` → http://localhost:8000 （API 文档 /docs）
   - 前端 `vite` → http://localhost:3000 （`/api`、`/ws` 自动代理到 8000）

打开 http://localhost:3000 即可使用。`Ctrl+C` 会同时停掉两个服务及其子进程并释放端口。

### 常用命令

```bash
make dev         # 预检 → 装依赖 → 构建检查 → 启动前后端（日常开发用这一条）
make build       # 只跑统一构建检查（CI / 提交前自查用同一条）
make install     # 只按锁定版本安装依赖
make preflight   # 只做工具链与端口预检
make clean       # 清理构建产物（frontend/dist、__pycache__、运行日志），不动依赖
make clean-deps  # 连 node_modules / .venv 一起删，下次自动按锁文件重装
make locks       # 升级依赖后重新生成两个锁文件（需提交）
make help        # 查看全部目标
```

### 出问题时看哪里

- 终端每一步都有 `==> [步骤名]` 标题；某一步失败时，最后一个标题就是卡住的步骤，下面紧跟失败原因和排查建议。
- 服务运行日志：`logs/run/backend.log`、`logs/run/frontend.log`（终端同时也实时打印，带 `[backend]` / `[frontend]` 前缀）。
- **端口被占用**：预检会打印形如 `端口 8000 已被占用 —— PID 1234：...`。确认后 `kill <PID>`，再重跑 `make dev`。脚本不会替你杀进程。
- **修好后重跑**：构建检查开始前固定先清理上次产物，不会吃到旧的中间结果；依赖目录如果损坏（例如从别的机器拷来的 `.venv`/`node_modules`）会自动删掉按锁文件重建。也可随时 `make clean-deps` 彻底重来。
- **换机器 / 换平台装不上**：`numpy`、`pydantic-core`、rollup 原生包与平台相关。锁文件需在目标平台上重新生成：升级或换平台后执行 `make locks` 并提交。

### 依赖版本是怎么锁定的

- 前端：`frontend/package.json` 用精确版本，`frontend/package-lock.json` 锁定整棵依赖树（**该文件已提交，不要加入 .gitignore**），安装一律走 `npm ci`。
- 后端：`backend/requirements.txt` 声明直接依赖，`backend/requirements.lock` 冻结全部传递依赖版本。
- 需要升级依赖：改 `package.json` 或 `requirements.txt` → 执行 `make locks` → 本地验证通过后把两个锁文件一起提交。
