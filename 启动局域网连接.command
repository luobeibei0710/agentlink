#!/bin/zsh
# Double-click on macOS. Keep this terminal open while using AgentLink.
set -eu
export AGENTLINK_OPEN_ADMIN=1
cd "${0:A:h}"
export PATH="$HOME/.local/bin:$HOME/.bun/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"
if [[ -z "${HAPI_BUN_BIN:-}" ]]; then
  if command -v bun >/dev/null 2>&1; then
    export HAPI_BUN_BIN="$(command -v bun)"
  else
    candidates=("$HOME"/.npm/_npx/*/node_modules/.bin/bun(N))
    if (( ${#candidates} == 0 )); then
      print '未找到 Bun。请先安装 Bun，再打开此文件。'
      read '?按回车退出'
      exit 1
    fi
    export HAPI_BUN_BIN="${candidates[1]}"
  fi
fi
print '手机和电脑连接同一 Wi-Fi，App 会自动发现电脑。首次请在管理页核对数字并允许。'
print '如电脑服务已在运行，请使用已有设备管理页核对数字，无需重复启动。'
node scripts/dev/agentlink-host.mjs --lan "$@" || {
  read '?启动失败，请查看上方原因。按回车退出'
  exit 1
}
