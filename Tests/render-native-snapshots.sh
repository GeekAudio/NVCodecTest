#!/bin/bash
set -euo pipefail
# 用途：离线重放已保存 JSON，生成明暗、活跃/失焦及 1×/2× 原生界面布局快照。
# 离屏缓存不代表所有系统合成效果；真实控件外观须通过 --preview 窗口检查。
# 用法：Tests/render-native-snapshots.sh /绝对路径/NVCodecTest /绝对路径/report.json [输出目录] [--window-frame]
# 依赖：macOS、已构建的当前版本程序；只重放报告，不运行环境探针或编解码测试。
SNAPSHOT_TEST_DIRECTORY="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SNAPSHOT_PROJECT_DIRECTORY="${SNAPSHOT_TEST_DIRECTORY%/Tests}"
if [[ $# -lt 2 || $# -gt 4 ]]; then
  echo "用法：$0 <程序路径> <已有报告.json> [输出目录] [--window-frame]" >&2
  exit 2
fi
SNAPSHOT_BINARY="$1"
SNAPSHOT_REPORT="$2"
SNAPSHOT_OUTPUT="${3:-$SNAPSHOT_PROJECT_DIRECTORY/build/ui-native-20261029/snapshots}"
SNAPSHOT_FRAME="${4:-}"
if [[ ! -x "$SNAPSHOT_BINARY" || ! -f "$SNAPSHOT_REPORT" ]]; then
  echo "程序必须可执行，且必须提供已保存的 JSON 报告。" >&2
  exit 2
fi
if [[ -n "$SNAPSHOT_FRAME" && "$SNAPSHOT_FRAME" != "--window-frame" ]]; then
  echo "第四个参数仅支持 --window-frame。" >&2
  exit 2
fi
mkdir -p "$SNAPSHOT_OUTPUT"
SNAPSHOT_MANIFEST="$SNAPSHOT_OUTPUT/render.log"
: > "$SNAPSHOT_MANIFEST"
for SNAPSHOT_APPEARANCE in light dark; do
  for SNAPSHOT_STATE in active inactive; do
    for SNAPSHOT_SCALE in 1 2; do
      SNAPSHOT_IMAGE="$SNAPSHOT_OUTPUT/$SNAPSHOT_APPEARANCE-$SNAPSHOT_STATE-${SNAPSHOT_SCALE}x.png"
      SNAPSHOT_ARGUMENTS=(--snapshot "$SNAPSHOT_IMAGE" --results-json "$SNAPSHOT_REPORT"
        "--$SNAPSHOT_APPEARANCE" --scale "$SNAPSHOT_SCALE" --width 860 --height 670)
      if [[ "$SNAPSHOT_STATE" == "inactive" ]]; then SNAPSHOT_ARGUMENTS+=(--inactive); fi
      if [[ -n "$SNAPSHOT_FRAME" ]]; then SNAPSHOT_ARGUMENTS+=("$SNAPSHOT_FRAME"); fi
      "$SNAPSHOT_BINARY" "${SNAPSHOT_ARGUMENTS[@]}" >> "$SNAPSHOT_MANIFEST" 2>&1
      if [[ ! -s "$SNAPSHOT_IMAGE" ]]; then
        echo "快照未生成：$SNAPSHOT_IMAGE" >&2
        exit 1
      fi
      /usr/bin/sips -g pixelWidth -g pixelHeight "$SNAPSHOT_IMAGE" >> "$SNAPSHOT_MANIFEST"
      echo "已渲染 $SNAPSHOT_APPEARANCE / $SNAPSHOT_STATE / ${SNAPSHOT_SCALE}×"
    done
  done
done
echo "快照与窗口状态记录：$SNAPSHOT_OUTPUT"
