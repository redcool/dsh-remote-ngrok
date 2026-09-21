# Re-apply the Codex-overload 2-minute self-retry patch (idempotent).
# Run:  pwsh reapply-codex-overload-retry-patch.ps1
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
& node (Join-Path $here 'reapply-codex-overload-retry-patch.cjs')
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
