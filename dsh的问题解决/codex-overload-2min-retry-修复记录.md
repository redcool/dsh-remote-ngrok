# Codex 过载错误自动重试补丁记录（2 分钟自循环）

> 2026-09-21 由 AI 会话实施。**npm install @deepseek-ai/dsh@latest 会覆盖 node_modules，升级后须重跑** `reapply-codex-overload-retry-patch.ps1`。

## 症状
- 运行（Codex 会话/轮次）整轮失败，报错：
  `Codex error: Our servers are currently overloaded. Please try again later.`
- 经常遇到，属于 OpenAI/ChatGPT 侧服务过载（transient），非本机问题。

## 根因链
1. `pi-ai`(`@earendil-works/pi-ai`) 的 Codex SSE/WS 流中途收到 `error` 事件 →
   `openai-codex-responses.js` 抛 `CodexApiError("Codex error: ...overloaded...")`。
2. `dsh-llm-pi-ai` 的 `classifyPiAiError` 把该文本判为 `PI_AI_ERROR` ——
   不在默认 `retryableCodes`（EMPTY_RESPONSE/RATE_LIMIT/SERVER/TIMEOUT/TRANSPORT）里。
3. `dsh-llm-retry` 的 `recover()` 见 code 不可重试 → 直接放行 → 整轮失败；
   且默认退避上限只有 10s，即使可重试也等不到"过几分钟"再试。

## 补丁内容（两处，均在 H:\AI\dsh\node_modules\@deepseek-ai 下）
### 1) dsh-llm-retry/lib/index.js — recover() 增加过载自循环
- 新增 `isTransientOverload(failure)`：匹配 `overloaded / our servers are currently / try again later`，
  并排除额度类措辞（quota/usage limit/insufficient/balance…），避免把真额度问题也无限重试。
- `recover()` 中：code 不在 retryableCodes 时，若 `isTransientOverload` 仍继续重试；
  延迟固定 `TRANSIENT_OVERLOAD_RETRY_DELAY_MS = 120_000`（2 分钟，可被 provider 的
  Retry-After 更长值覆盖），仍受 `policy.maxRetries`（默认 5）约束——最多约 10 分钟自循环后放弃。
- 重试走既有机制：`backoff()` → `llm/retry` 事件 → `{kind:"retry"}` → agent-loop `continue` 重发请求，
  数量持久化在 sessionProjections `llmRetry` 键下，中断可续。

### 2) dsh-llm-pi-ai/lib/index.js — classifyPiAiError 增加过载识别
- 新增：`/\boverload(?:ed)?\b|our servers are currently overloaded|please try again later/i` → `RATE_LIMIT`
  （RATE_LIMIT 本就在默认 retryableCodes 内），让错误码与诊断一致。

## 验证
- `node --check` 两个 lib/index.js 均通过。
- 之后重启 `dsh web`（node 进程常驻缓存，不重启不生效）；重启后再触发一次过载，
  会话里应出现 `llm/retry` / `llm/retry-started` 事件，约 2 分钟后自动重发请求。

## 回滚
- 删除本记录、反向替换两处代码即可；或直接 `npm install @deepseek-ai/dsh@latest` 重装该包。
## 一键重打 / 回滚脚本（升级后必用）
- **文件**：`reapply-codex-overload-retry-patch.cjs`（自包含，内嵌完整补丁块）+ `reapply-codex-overload-retry-patch.ps1`（薄包装，调 node）。
- **用法**（管理员权限无所谓，直接跑即可）：
  - 重打（升级后）：`pwsh reapply-codex-overload-retry-patch.ps1` —— 幂等，已打补丁会报 ALREADY PATCHED，不会重复插入；
  - 回滚：`$env:DSH_PATCH_REVERSE='1'; node reapply-codex-overload-retry-patch.cjs`；
  - 测试指向任意文件：`$env:DSH_PATCH_RETRY=<路径>`、`$env:DSH_PATCH_PIAI=<路径>`。
- **幂等性细节**（已修过的坑）：pi-ai 那处 hunk 的 `old` 是 `new` 的**前缀**，先查 old 会把已打补丁的文件再插一遍（首次版本确认有该 bug，已改为**先查 new**；reverse 模式靠 fwdNew 存在性判定，同样规避前缀歧义）。
- **已经历的变更**：cjs 内嵌完整大块（overload helper + 2 分钟分支 + 分类行），recover 全文 old/new 对；E2E round-trip 在临时副本验证：reverse → re-apply → 与 live 逐字节 IDENTICAL，语法通过。
- **注意**：升级会重写 `lib/index.js`（路径/缩进/上下文可能微变）。若脚本报 `HUNK NOT FOUND (version changed?)`，按本记录手工重打。

## 升级后操作清单（写在 H:\AI\dsh\更新.txt 里）
1. `npm install @deepseek-ai/dsh@latest`
2. `pwsh "H:\Works\FeiTuTeamPrj\dsh-remote\dsh的问题解决\reapply-codex-overload-retry-patch.ps1"`
3. 重启 `dsh web`。

## 回滚（原方法）
- `npm install @deepseek-ai/dsh@latest` 重装即覆盖；或跑 reverse 模式脚本。
