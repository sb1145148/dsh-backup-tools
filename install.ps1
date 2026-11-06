# dsh-backup-tools 一键安装
#
# 用法（PowerShell）：
#   iex ([Text.Encoding]::UTF8.GetString((irm https://raw.githubusercontent.com/sb1145148/dsh-backup-tools/main/install.ps1).Content))
#
# 或者下载后带参数跑：
#   .\install.ps1 -Dir D:\Tools\dsh-backup-tools -Register
#
# 参数：
#   -Dir        安装目录（默认 %USERPROFILE%\dsh-backup-tools）
#   -Register   装完顺手注册计划任务
#   -NoVerify   跳过安装后的体检

param(
  [string]$Dir = (Join-Path $env:USERPROFILE 'dsh-backup-tools'),
  [switch]$Register,
  [switch]$NoVerify
)

$ErrorActionPreference = 'Stop'
$Repo = 'sb1145148/dsh-backup-tools'
$Branch = 'main'

function Info($m) { Write-Host $m -ForegroundColor Cyan }
function Ok($m)   { Write-Host $m -ForegroundColor Green }
function Die($m)  { Write-Host "安装失败: $m" -ForegroundColor Red; exit 1 }

Info "== dsh-backup-tools 安装 =="
Info "目标目录: $Dir"

# ---------- 1. 下载 ----------
$tmp = Join-Path $env:TEMP ("dsh-backup-tools-" + (Get-Date -Format 'yyyyMMdd-HHmmss'))
New-Item -ItemType Directory -Force -Path $tmp | Out-Null

$zip = Join-Path $tmp 'src.zip'
$zipUrl = "https://codeload.github.com/$Repo/zip/refs/heads/$Branch"
Info "下载 $zipUrl"
try {
  $old = $ProgressPreference
  $ProgressPreference = 'SilentlyContinue'
  Invoke-WebRequest -Uri $zipUrl -OutFile $zip -TimeoutSec 120 -UseBasicParsing
  $ProgressPreference = $old
} catch {
  # 备用：逐个下 raw 文件
  Info "zip 下载失败，改用 raw 文件"
  $files = @('dsh-backup.ps1', 'setup-task.ps1', 'README.md', 'lib/inspect-sessions.mjs')
  foreach ($f in $files) {
    $out = Join-Path $tmp $f
    New-Item -ItemType Directory -Force -Path (Split-Path $out -Parent) | Out-Null
    $u = "https://raw.githubusercontent.com/$Repo/$Branch/$f"
    try { Invoke-WebRequest -Uri $u -OutFile $out -TimeoutSec 60 -UseBasicParsing }
    catch { Die "下载 $f 失败：$($_.Exception.Message)" }
  }
}

# ---------- 2. 解压 / 落位 ----------
New-Item -ItemType Directory -Force -Path $Dir | Out-Null

if (Test-Path $zip) {
  $expanded = Join-Path $tmp 'expanded'
  try { Expand-Archive -Path $zip -DestinationPath $expanded -Force }
  catch { Die "解压失败：$($_.Exception.Message)" }

  $root = Get-ChildItem $expanded -Directory | Select-Object -First 1
  if (-not $root) { Die '解压出来的目录是空的' }

  Copy-Item (Join-Path $root.FullName '*') $Dir -Recurse -Force
} else {
  Copy-Item (Join-Path $tmp '*') $Dir -Recurse -Force
}

# 清掉不该带走的东西
Remove-Item (Join-Path $Dir '.git') -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue

$main = Join-Path $Dir 'dsh-backup.ps1'
if (-not (Test-Path $main)) { Die "没找到 dsh-backup.ps1（$Dir）" }
Ok "已安装到 $Dir"

# ---------- 3. 自检 ----------
if (-not $NoVerify) {
  Info ""
  Info "跑一次体检确认能读会话…"
  & powershell -NoProfile -ExecutionPolicy Bypass -File $main check
  if ($LASTEXITCODE -ne 0) { Write-Host "体检报有问题（不影响使用，可后续用 check 细看）" -ForegroundColor Yellow }
}

# ---------- 4. 计划任务 ----------
if ($Register) {
  Info ""
  Info "注册计划任务…"
  & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Dir 'setup-task.ps1')
}

# ---------- 5. 下一步提示 ----------
Write-Host ""
Ok "安装完成"
Write-Host ""
Write-Host "下一步：" -ForegroundColor Cyan
Write-Host "  1) 配置备份仓库（默认指向作者自己的，务必改成你的）："
Write-Host "     $main pack -Repo `"你的用户名/你的私有备份仓库`""
Write-Host ""
Write-Host "  2) 写令牌（只放本机，别提交）："
Write-Host "     Set-Content -Path `"`$env:USERPROFILE\.dsh-backup-token`" -Value `"github_pat_xxx`" -NoNewline"
Write-Host ""
Write-Host "  3) 注册自动备份（建议管理员身份）："
Write-Host "     & `"$Dir\setup-task.ps1`""
Write-Host ""
Write-Host "  常用命令："
Write-Host "     $main check              # 体检"
Write-Host "     $main pack               # 立即备份并上传"
Write-Host "     $main pack -AttachmentsOnly   # 附件备份（每月一次）"
Write-Host "     $main list               # 看本地与云端备份"
