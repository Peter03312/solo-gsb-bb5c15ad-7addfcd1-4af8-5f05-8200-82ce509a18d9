#!/usr/bin/env bash
# 山洪水位预警裁定服务 —— 端到端调用示例
# 用法：先启动服务（见 README），再执行 ./examples/demo.sh
set -euo pipefail

BASE="${BASE:-http://127.0.0.1:8000}"
J='content-type: application/json'

step() { printf '\n\033[1m== %s ==\033[0m\n' "$1"; }

step "1. 登记监测站（上升阈值 10.0，解除阈值 8.0）"
curl -s -X POST "$BASE/stations" -H "$J" \
  -d '{"name":"青石峡站","rise_threshold":10.0,"clear_threshold":8.0}' ; echo

step "2. 为监测站登记设备 DEV-001"
curl -s -X POST "$BASE/stations/1/devices" -H "$J" -d '{"device_no":"DEV-001"}'; echo

step "3. 设备补传读数（设备号 + 设备内序号 + 带时区观测时间 + 水位）"
for m in 00 05 10; do
  curl -s -X POST "$BASE/readings" -H "$J" \
    -d "{\"device_no\":\"DEV-001\",\"seq\":1$m,\"observed_at\":\"2026-10-01T08:$m:00+08:00\",\"water_level\":12.0}"; echo
done

step "4. 同号同序号同内容重试 → 返回原结果（deduplicated=true）"
curl -s -X POST "$BASE/readings" -H "$J" \
  -d '{"device_no":"DEV-001","seq":110,"observed_at":"2026-10-01T00:10:00Z","water_level":12.0}'; echo

step "5. 同号同序号异内容 → 409 冲突"
curl -s -o /dev/null -w 'HTTP %{http_code}\n' -X POST "$BASE/readings" -H "$J" \
  -d '{"device_no":"DEV-001","seq":110,"observed_at":"2026-10-01T08:10:00+08:00","water_level":13.0}'

step "6. 待发布裁定时间线（3 个读数达阈值、首尾 10 分钟 → 预警）"
curl -s "$BASE/stations/1/timeline"; echo

step "7. 发布：冻结公开结果"
curl -s -X POST "$BASE/publish" -H "$J" -d '{"note":"例行发布"}'; echo

step "8. 补传解除读数（2 条 ≤8.0，首尾 6 分钟 ≥5 → 待发布解除）"
curl -s -X POST "$BASE/readings" -H "$J" \
  -d '{"device_no":"DEV-001","seq":115,"observed_at":"2026-10-01T08:15:00+08:00","water_level":7.0}' > /dev/null
curl -s -X POST "$BASE/readings" -H "$J" \
  -d '{"device_no":"DEV-001","seq":121,"observed_at":"2026-10-01T08:21:00+08:00","water_level":7.0}' > /dev/null
echo "待发布状态: $(curl -s "$BASE/stations/1/timeline" | python3 -c 'import sys,json;print(json.load(sys.stdin)["status"])')"
echo "公开状态（仍冻结为预警）: $(curl -s "$BASE/public/stations/1/timeline" | python3 -c 'import sys,json;print(json.load(sys.stdin)["status"])')"

step "9. 审核员更正读数（带原因），裁定随之重算"
curl -s -X POST "$BASE/readings/1/correct" -H "$J" \
  -d '{"water_level":9.0,"reason":"比测后修正","auditor":"王审"}'; echo

step "10. 查询原值与历次修订"
curl -s "$BASE/readings/1/revisions"; echo

step "11. 重新发布 → 公开结果更新"
curl -s -X POST "$BASE/publish" > /dev/null
curl -s "$BASE/public/stations/1/timeline"; echo

step "12. 作废读数示例（读数 2，带原因）"
curl -s -X POST "$BASE/readings/2/void" -H "$J" \
  -d '{"reason":"传感器故障","auditor":"李审"}'; echo

step "13. 防汛方案调整：登记阈值版本（带时区生效时间/上升阈值/解除阈值/原因）"
# 新版本自 08:30(+08:00) 起生效：上升阈值上调到 15.0、解除阈值上调到 12.0
curl -s -X POST "$BASE/stations/1/threshold-versions" -H "$J" \
  -d '{"effective_at":"2026-10-01T08:30:00+08:00","rise_threshold":15.0,"clear_threshold":12.0,"reason":"入汛方案调整","created_by":"张工"}'; echo

step "14. 查询阈值版本历史（含未命中版本时使用的登记基准阈值）"
curl -s "$BASE/stations/1/threshold-versions"; echo

step "15. 阈值版本按观测时间逐读数生效：补传 08:30 后的读数"
# 水位 13.0 在旧基准（上升 10.0）下必预警，但在新版本（上升 15.0）下不预警
curl -s -X POST "$BASE/readings" -H "$J" \
  -d '{"device_no":"DEV-001","seq":130,"observed_at":"2026-10-01T08:30:00+08:00","water_level":13.0}' > /dev/null
curl -s -X POST "$BASE/readings" -H "$J" \
  -d '{"device_no":"DEV-001","seq":135,"observed_at":"2026-10-01T08:35:00+08:00","water_level":13.0}' > /dev/null
curl -s -X POST "$BASE/readings" -H "$J" \
  -d '{"device_no":"DEV-001","seq":140,"observed_at":"2026-10-01T08:40:00+08:00","water_level":13.0}' > /dev/null
# 08:45 起三条 16.0 ≥ 新版本上升阈值 15.0、首尾 10 分钟 → 按新版本预警
curl -s -X POST "$BASE/readings" -H "$J" \
  -d '{"device_no":"DEV-001","seq":145,"observed_at":"2026-10-01T08:45:00+08:00","water_level":16.0}' > /dev/null
curl -s -X POST "$BASE/readings" -H "$J" \
  -d '{"device_no":"DEV-001","seq":150,"observed_at":"2026-10-01T08:50:00+08:00","water_level":16.0}' > /dev/null
curl -s -X POST "$BASE/readings" -H "$J" \
  -d '{"device_no":"DEV-001","seq":155,"observed_at":"2026-10-01T08:55:00+08:00","water_level":16.0}' > /dev/null
echo "待发布时间线（事件携带 threshold_version_no 与当时阈值）："
curl -s "$BASE/stations/1/timeline"; echo

step "16. 拒绝非法阈值版本（依次为：重复生效时间 409 / 上升<=解除 400 / 无时区 400）"
curl -s -o /dev/null -w '重复生效时间(同一时刻换+08:00表示) -> HTTP %{http_code}\n' \
  -X POST "$BASE/stations/1/threshold-versions" -H "$J" \
  -d '{"effective_at":"2026-10-01T00:30:00Z","rise_threshold":16.0,"clear_threshold":10.0,"reason":"重复时刻"}'
curl -s -o /dev/null -w '上升阈值不大于解除阈值 -> HTTP %{http_code}\n' \
  -X POST "$BASE/stations/1/threshold-versions" -H "$J" \
  -d '{"effective_at":"2026-10-01T09:00:00+08:00","rise_threshold":12.0,"clear_threshold":12.0,"reason":"非法阈值"}'
curl -s -o /dev/null -w '生效时间不带时区 -> HTTP %{http_code}\n' \
  -X POST "$BASE/stations/1/threshold-versions" -H "$J" \
  -d '{"effective_at":"2026-10-01T09:00:00","rise_threshold":16.0,"clear_threshold":10.0,"reason":"无时区"}'
curl -s -o /dev/null -w '站点不存在 -> HTTP %{http_code}\n' \
  -X POST "$BASE/stations/999/threshold-versions" -H "$J" \
  -d '{"effective_at":"2026-10-01T09:00:00+08:00","rise_threshold":16.0,"clear_threshold":10.0,"reason":"无此站"}'
