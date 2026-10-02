# 山洪水位预警裁定服务

基于 **Python + FastAPI + SQLite** 的山洪水位预警裁定服务：监测站/设备登记、读数幂等补传、按规则自动裁定预警与解除、审核修订并重算、发布冻结公开结果。

## 一键启动

### 方式一：Docker Compose（推荐）

```bash
docker compose up --build
```

### 方式二：Docker

```bash
docker build -t flood-warning-service .
docker run -d -p 8000:8000 -v flood-data:/data --name flood-warning flood-warning-service
```

### 方式三：本地运行

```bash
pip install -r requirements.txt
uvicorn app.main:app --host 0.0.0.0 --port 8000
```

启动时自动完成 SQLite 建表初始化，无需额外迁移步骤。

## 地址与端口

| 项 | 地址 |
|---|---|
| 服务地址 | http://127.0.0.1:8000 |
| 交互式 API 文档（Swagger） | http://127.0.0.1:8000/docs |
| OpenAPI  schema | http://127.0.0.1:8000/openapi.json |
| 健康检查 | `GET /health` |

## 配置（环境变量）

| 变量 | 默认值 | 说明 |
|---|---|---|
| `FLOOD_DB_PATH` | `./data/flood.db`（容器内 `/data/flood.db`） | SQLite 数据库文件路径 |
| `FLOOD_MIN_WATER_LEVEL` | `-50` | 水位合法下限，超出报 400 |
| `FLOOD_MAX_WATER_LEVEL` | `1000` | 水位合法上限，超出报 400 |
| `FLOOD_SEGMENT_GAP_MINUTES` | `15` | 相邻读数间隔超过该值即断段 |
| `FLOOD_RISE_MIN_COUNT` | `3` | 预警所需同段连续达上升阈值读数个数 |
| `FLOOD_RISE_MIN_SPAN_MINUTES` | `10` | 预警所需连续段首尾最小间隔（分钟） |
| `FLOOD_CLEAR_MIN_COUNT` | `2` | 解除所需连续不高于解除阈值读数个数 |
| `FLOOD_CLEAR_MIN_SPAN_MINUTES` | `5` | 解除所需连续段首尾最小间隔（分钟） |

## 裁定规则

1. 有效（未作废）读数按**观测时间**升序重排，相邻间隔 **> 15 分钟**即断段；
2. **预警**：同段内连续 **≥ 3** 个读数水位 **≥ 上升阈值**，且该连续段首尾相隔 **≥ 10 分钟**——在首次同时满足两项条件的读数时刻发出预警；
3. **解除**：预警状态下连续 **≥ 2** 个读数水位 **≤ 解除阈值**，且首尾相隔 **≥ 5 分钟**——在满足条件的读数时刻解除；
4. 断段只重置上升计数；**断段本身不自动解除预警**，解除计数可跨段延续；
5. **阈值版本（防汛方案调整）**：每条有效读数按观测时间采用“**最近已生效**”的阈值版本，**同一时刻采用新版本**；观测时间早于任何版本时，使用监测站**登记阈值作为基准值**。跨版本的连续读数分别按各自阈值判断，断段与解除规则不变；
6. **阈值调整本身不产生预警或解除事件**，事件只由读数触发；预警/解除事件会附带 `threshold_version_no`（基准阈值为 `null`）与当时适用的 `rise_threshold`/`clear_threshold`，便于溯源；
7. 审核员**作废/更正**读数、或登记/补登阈值版本后，待发布裁定立即按全部有效读数重算；**发布**将各站时间线冻结为公开结果，之后的补传/修订/阈值调整只影响待发布结果，**重新发布**才更新公开结果。历史发布快照永久保持发布时的内容。

## API 一览

### 监测站与设备

| 方法 | 路径 | 说明 |
|---|---|---|
| POST | `/stations` | 登记监测站（上升阈值必须严格大于解除阈值，否则 400） |
| GET | `/stations` / `/stations/{id}` | 查询监测站 |
| POST | `/stations/{id}/devices` | 登记设备（设备号全局唯一，重复 409） |
| GET | `/stations/{id}/devices` | 查询站内设备 |

### 阈值版本（防汛方案调整）

| 方法 | 路径 | 说明 |
|---|---|---|
| POST | `/stations/{id}/threshold-versions` | 登记阈值版本：`{effective_at, rise_threshold, clear_threshold, reason, created_by?}` |
| GET | `/stations/{id}/threshold-versions` | 版本历史（含未命中版本时的登记基准阈值） |
| GET | `/stations/{id}/threshold-versions/{version_no}` | 查询单个阈值版本 |

请求体字段：

| 字段 | 必填 | 说明 |
|---|---|---|
| `effective_at` | 是 | 带时区的生效时间（如 `2026-10-01T08:30:00+08:00` 或 `2026-10-01T00:30:00Z`），无时区 400 |
| `rise_threshold` | 是 | 上升阈值，必须为有限数值，且**严格大于** `clear_threshold`，否则 400 |
| `clear_threshold` | 是 | 解除阈值，必须为有限数值（拒绝 `NaN`/`Infinity`） |
| `reason` | 是 | 调整原因（1–500 字） |
| `created_by` | 否 | 登记人 |

- 同一监测站**重复生效时间**（不同时区表示的同一时刻也算）→ **409**；站点不存在 → **404**；
- 版本号站内从 1 递增，允许补登**历史生效时间**（立即作用于全部有效读数的重算），也允许登记**未来生效时间**（到期自动适用，无需启用操作）；
- 时间线响应新增 `threshold_versions` 列表，事件新增 `threshold_version_no` / `rise_threshold` / `clear_threshold` 字段；登记站/读数/修订/发布接口的请求与既有响应字段保持不变（仅新增字段，向后兼容）。

### 读数补传（幂等）

| 方法 | 路径 | 说明 |
|---|---|---|
| POST | `/readings` | 补传读数：`{device_no, seq, observed_at, water_level}` |
| GET | `/stations/{id}/readings?include_voided=false` | 查询站内读数 |
| GET | `/readings/{id}` | 查询单条读数 |

- `observed_at` 必须带时区（如 `2026-10-01T08:00:00+08:00` 或 `...Z`），否则 400；
- 水位须为有限数值且在合法范围内，否则 400；未知设备号 404；
- **同设备号 + 同序号 + 同内容**重试 → 200 返回原结果（`deduplicated: true`）；
- **同设备号 + 同序号 + 异内容** → 409 冲突，不写入。

### 审核（作废 / 更正 / 历史）

| 方法 | 路径 | 说明 |
|---|---|---|
| POST | `/readings/{id}/void` | 作废读数，必填 `reason`，可带 `auditor` |
| POST | `/readings/{id}/correct` | 更正观测时间和/或水位，必填 `reason` |
| GET | `/readings/{id}/revisions` | 查询原值与历次修订 |

作废/更正后响应中直接附带重算后的待发布裁定状态。

### 裁定与发布

| 方法 | 路径 | 说明 |
|---|---|---|
| GET | `/stations/{id}/timeline` | 待发布裁定时间线（实时重算） |
| POST | `/publish` | 发布：冻结全部监测站当前时间线 |
| GET | `/publications` / `/publications/{id}` | 查询历史发布版本 |
| GET | `/public/current` | 最新发布的公开结果 |
| GET | `/public/stations/{id}/timeline` | 某站最新公开时间线 |

## 调用示例

完整端到端示例脚本（登记 → 补传 → 幂等重试 → 冲突 → 预警 → 发布 → 解除 → 更正 → 重发布 → 作废 → 阈值版本调整与版本历史 → 非法调整被拒）：

```bash
./examples/demo.sh            # 默认打 http://127.0.0.1:8000
BASE=http://127.0.0.1:8000 ./examples/demo.sh
```

curl 速览：

```bash
# 登记监测站与设备
curl -X POST http://127.0.0.1:8000/stations \
  -H 'content-type: application/json' \
  -d '{"name":"青石峡站","rise_threshold":10.0,"clear_threshold":8.0}'
curl -X POST http://127.0.0.1:8000/stations/1/devices \
  -H 'content-type: application/json' -d '{"device_no":"DEV-001"}'

# 设备补传读数（带时区观测时间）
curl -X POST http://127.0.0.1:8000/readings \
  -H 'content-type: application/json' \
  -d '{"device_no":"DEV-001","seq":1,"observed_at":"2026-10-01T08:00:00+08:00","water_level":12.0}'

# 查看待发布裁定时间线
curl http://127.0.0.1:8000/stations/1/timeline

# 发布并查看公开结果
curl -X POST http://127.0.0.1:8000/publish
curl http://127.0.0.1:8000/public/current

# 审核更正（带原因）并查看修订历史
curl -X POST http://127.0.0.1:8000/readings/1/correct \
  -H 'content-type: application/json' \
  -d '{"water_level":9.0,"reason":"比测后修正","auditor":"王审"}'
curl http://127.0.0.1:8000/readings/1/revisions

# 防汛方案调整：登记阈值版本（带时区生效时间 + 双阈值 + 原因）
curl -X POST http://127.0.0.1:8000/stations/1/threshold-versions \
  -H 'content-type: application/json' \
  -d '{"effective_at":"2026-10-01T08:30:00+08:00","rise_threshold":15.0,"clear_threshold":12.0,"reason":"入汛方案调整","created_by":"张工"}'

# 查询阈值版本历史（baseline 为未命中版本时的登记基准阈值）
curl http://127.0.0.1:8000/stations/1/threshold-versions
```

## 并发与一致性设计

- 所有写操作（补传、作废、更正、阈值版本登记、发布）在 **`BEGIN IMMEDIATE` 事务**中执行，并由进程内锁串行化；SQLite 开启 **WAL + busy_timeout**，并发请求不会丢失已提交记录；
- `readings(device_id, seq)` **唯一约束**是幂等的最终防线：并发下同序号写只成功一次，其余按内容比对返回原结果或 409；
- `threshold_versions(station_id, effective_at)` 与 `(station_id, version_no)` 唯一约束保证同站生效时间不重复、版本号不冲突；并发登记同一生效时间只成功一次，其余 409；
- 发布在单事务内为全部监测站生成快照，公开结果读取的是冻结快照，与后续写入（含阈值调整）互不影响。

## 测试

```bash
pip install -r requirements-dev.txt
pytest tests/ -q
```

覆盖：阈值/时间/水位/设备校验、幂等与冲突、预警与解除规则（含断段、乱序重排、跨段解除）、作废与更正重算、修订历史、**阈值版本（版本校验与重复生效时间、基准阈值回退、同一时刻取新版本、跨版本分别裁定、调整本身不产生事件、更正/作废后按版本重算、发布快照不受事后版本调整影响）**、发布冻结、并发补传/发布/并发版本登记不丢记录。

## 项目结构

```
app/
  adjudication.py   # 裁定核心（纯函数：分段、预警、解除；读数可携带按版本命中的阈值）
  config.py         # 环境变量配置
  db.py             # SQLite 连接、事务与建表（含 threshold_versions）
  schemas.py        # 请求模型与校验（含阈值版本）
  main.py           # FastAPI 路由与应用工厂
tests/test_api.py   # 端到端测试（42 例）
examples/demo.sh    # 调用示例脚本（含阈值版本调整）
Dockerfile / docker-compose.yml
```
