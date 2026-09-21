'use strict';
// Re-apply (or revert) the Codex-overload 2-minute self-retry patch.
// Forward (default): re-applies after dsh upgrades (npm install overwrites node_modules).
// Reverse: set env DSH_PATCH_REVERSE=1 to remove the patch (rollback).
// Idempotent either way; explicit env overrides DSH_PATCH_RETRY / DSH_PATCH_PIAI for testing.
const fs = require('fs');

const RETRY_FILE = process.env.DSH_PATCH_RETRY || 'H:\\AI\\dsh\\node_modules\\@deepseek-ai\\dsh-llm-retry\\lib\\index.js';
const PIAI_FILE = process.env.DSH_PATCH_PIAI || 'H:\\AI\\dsh\\node_modules\\@deepseek-ai\\dsh-llm-pi-ai\\lib\\index.js';

const ORIG_RETRY = "\tasync function recover({ agent, turn, step, provider, failure, retryPolicy: policy, signal }, next) {\n\t\tif (policy === void 0) return next();\n\t\tif (policy.mode === \"always\") {\n\t\t\tif (signal.aborted || lifetime.signal.aborted) return;\n\t\t\tconst fusedSignal = AbortSignal.any([signal, lifetime.signal]);\n\t\t\tconst downstream = await settleDownstream(next);\n\t\t\tif (fusedSignal.aborted) return;\n\t\t\tif (downstream.type === \"error\") ctx.logger.warn(`llm-retry: provider \"${provider}\" always policy ignored a downstream recovery failure: %o`, downstream.error);\n\t\t\tif (downstream.type === \"decision\" && downstream.decision?.kind === \"retry\") return downstream.decision;\n\t\t} else if (!policy.retryableCodes.includes(failure.code)) return next();\n\t\tconst policyKey = retryPolicyKey(policy);\n\t\tconst previous = ctx.sessionProjections.stateOf(agent.session, \"llmRetry\")[retryStateKey(provider, policyKey)];\n\t\tconst previousRetry = previous?.retry ?? 0;\n\t\tif (policy.mode === \"normal\" && previousRetry >= policy.maxRetries) return next();\n\t\tconst retry = previousRetry + 1;\n\t\tconst retryId = previous?.retryId ?? RetryId(randomUUID());\n\t\tlet delayMs;\n\t\tif (failure.providerRetryAfterMs !== void 0 && Number.isFinite(failure.providerRetryAfterMs) && failure.providerRetryAfterMs > 0) if (failure.providerRetryAfterMs > policy.maxDelayMs) {\n\t\t\tif (policy.mode === \"normal\") return next();\n\t\t\tdelayMs = localDelay(policy, retry, random);\n\t\t} else delayMs = failure.providerRetryAfterMs;\n\t\telse delayMs = localDelay(policy, retry, random);\n\t\treturn backoff(agent, turn, step, failure, provider, policy, policyKey, retry, retryId, delayMs, signal);\n\t}";
const PATCHED_RETRY = "/**\n * Transient server-overload failures (e.g. Codex \"Our servers are currently\n * overloaded. Please try again later.\") must self-retry after a long pause\n * instead of failing the run immediately: server overload clears in minutes,\n * and a short backoff just re-collides with the outage. Terminal quota and\n * usage-limit wording is excluded — those must surface to the user.\n */\nconst TRANSIENT_OVERLOAD_RETRY_DELAY_MS = 120_000;\nconst TRANSIENT_OVERLOAD_PATTERN = /\\boverload(?:ed)?\\b|our servers are currently|try again later/i;\nconst TRANSIENT_OVERLOAD_TERMINAL_PATTERN = /quota|usage[\\s_-]+limit|insufficient|out[\\s_-]+of[\\s_-]+(?:credits?|budget)|billing|balance/i;\nfunction isTransientOverload(failure) {\n\tconst message = failure?.message;\n\tif (typeof message !== \"string\" || message.length === 0) return false;\n\tif (!TRANSIENT_OVERLOAD_PATTERN.test(message)) return false;\n\treturn !TRANSIENT_OVERLOAD_TERMINAL_PATTERN.test(message);\n}\n\tasync function recover({ agent, turn, step, provider, failure, retryPolicy: policy, signal }, next) {\n\t\tif (policy === void 0) return next();\n\t\tif (policy.mode === \"always\") {\n\t\t\tif (signal.aborted || lifetime.signal.aborted) return;\n\t\t\tconst fusedSignal = AbortSignal.any([signal, lifetime.signal]);\n\t\t\tconst downstream = await settleDownstream(next);\n\t\t\tif (fusedSignal.aborted) return;\n\t\t\tif (downstream.type === \"error\") ctx.logger.warn(`llm-retry: provider \"${provider}\" always policy ignored a downstream recovery failure: %o`, downstream.error);\n\t\t\tif (downstream.type === \"decision\" && downstream.decision?.kind === \"retry\") return downstream.decision;\n\t\t} else if (!policy.retryableCodes.includes(failure.code) && !isTransientOverload(failure)) return next();\n\t\tconst policyKey = retryPolicyKey(policy);\n\t\tconst previous = ctx.sessionProjections.stateOf(agent.session, \"llmRetry\")[retryStateKey(provider, policyKey)];\n\t\tconst previousRetry = previous?.retry ?? 0;\n\t\tif (policy.mode === \"normal\" && previousRetry >= policy.maxRetries) return next();\n\t\tconst retry = previousRetry + 1;\n\t\tconst retryId = previous?.retryId ?? RetryId(randomUUID());\n\t\tlet delayMs;\n\t\tif (isTransientOverload(failure)) {\n\t\t\tdelayMs = TRANSIENT_OVERLOAD_RETRY_DELAY_MS;\n\t\t\tif (failure.providerRetryAfterMs !== void 0 && Number.isFinite(failure.providerRetryAfterMs) && failure.providerRetryAfterMs > delayMs) {\n\t\t\t\tdelayMs = failure.providerRetryAfterMs;\n\t\t\t}\n\t\t} else if (failure.providerRetryAfterMs !== void 0 && Number.isFinite(failure.providerRetryAfterMs) && failure.providerRetryAfterMs > 0) if (failure.providerRetryAfterMs > policy.maxDelayMs) {\n\t\t\tif (policy.mode === \"normal\") return next();\n\t\t\tdelayMs = localDelay(policy, retry, random);\n\t\t} else delayMs = failure.providerRetryAfterMs;\n\t\telse delayMs = localDelay(policy, retry, random);\n\t\treturn backoff(agent, turn, step, failure, provider, policy, policyKey, retry, retryId, delayMs, signal);\n\t}";
const PIAI_OLD = "\tif (/\\b429\\b|rate.?limit/i.test(message)) return \"RATE_LIMIT\";";
const PIAI_NEW = "\tif (/\\b429\\b|rate.?limit/i.test(message)) return \"RATE_LIMIT\";\n\tif (/\\boverload(?:ed)?\\b|our servers are currently overloaded|please try again later/i.test(message)) return \"RATE_LIMIT\";";

function apply(file, fwdOld, fwdNew, label, reverse) {
  if (!fs.existsSync(file)) { console.log('MISSING: ' + file); return; }
  const raw = fs.readFileSync(file, 'utf8');
  // Prefix-proof already-check: for hunk 2, fwdOld (PIAI_OLD) is a *prefix* of
  // fwdNew (PIAI_NEW), so `includes(fwdOld)` is true in both states and cannot
  // distinguish patched from unpatched. The only unambiguous signal is whether
  // fwdNew is present:
  //   - forward: already patched  = fwdNew present;
  //   - reverse: already reverted = fwdNew ABSENT.
  if (reverse) {
    if (!raw.includes(fwdNew)) { console.log('ALREADY REVERTED: ' + file + ' [' + label + ']'); return; }
    const out = raw.split(fwdNew).join(fwdOld);
    fs.writeFileSync(file, out, 'utf8');
    console.log('REVERTED: ' + file + ' [' + label + ']');
    return;
  }
  if (raw.includes(fwdNew)) { console.log('ALREADY PATCHED: ' + file + ' [' + label + ']'); return; }
  if (raw.includes(fwdOld)) {
    const out = raw.split(fwdOld).join(fwdNew);
    fs.writeFileSync(file, out, 'utf8');
    console.log('PATCHED: ' + file + ' [' + label + ']');
  } else {
    console.log('HUNK NOT FOUND (version changed?): ' + file + ' [' + label + ']');
  }
}

const REVERSE = process.env.DSH_PATCH_REVERSE === '1';
if (REVERSE) console.log('=== REVERSE MODE: removing the overload-retry patch ===');
apply(RETRY_FILE, ORIG_RETRY, PATCHED_RETRY, 'llm-retry recover', REVERSE);
apply(PIAI_FILE, PIAI_OLD, PIAI_NEW, 'pi-ai classify', REVERSE);

if (fs.existsSync(RETRY_FILE)) {
  const c = fs.readFileSync(RETRY_FILE, 'utf8');
  console.log(c.includes('TRANSIENT_OVERLOAD_RETRY_DELAY_MS')
    ? 'OVERLOAD DELAY BLOCK present in dsh-llm-retry.'
    : 'WARN: dsh-llm-retry missing the overload-delay block — inspect manually.');
}
console.log('Done. Restart "dsh web" for changes to take effect.');
