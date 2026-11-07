# dsh-backup —— DSH 独立备份工具（Windows）
#
# 子命令：
#   .\dsh-backup.ps1 check                     # 体检：会话格式 / seq 连续 / 空会话
#   .\dsh-backup.ps1 pack                      # 打包 + 校验 + 轮转 +（默认）上传
#   .\dsh-backup.ps1 pack -Full                # 连 attachments 一起（只留本地）
#   .\dsh-backup.ps1 pack -NoUpload            # 不上传
#   .\dsh-backup.ps1 list                      # 本地 + 云端备份清单
#   .\dsh-backup.ps1 restore <包> [-Force]     # 还原（默认先解到临时目录校验）
#
# 和 dsh-tools 的区别：
#   · 打包前体检、打包后「解回来再体检」——两级校验
#   · 包里带 manifest.json（时间、条目、会话数与 seq 范围）
#   · 自动上传到私有 Release，并清理旧版本
#   · 核心/完整备份分开轮转（不会互相挤掉）

param(
  [Parameter(Position = 0)][string]$Command = 'check',
  [Parameter(Position = 1)][string]$Target,
  [switch]$Full,
  [switch]$AttachmentsOnly,
  [switch]$NoUpload,
  [switch]$Upload,
  [switch]$Force,
  [int]$IfFreshHours = 0,
  [int]$KeepCore = 7,
  [int]$KeepFull = 3,
  [int]$KeepAttach = 12,
  [int]$KeepReleases = 10,
  [string]$LocalDir = 'D:\Backup\dsh-backups',
  [string]$Repo = 'sb1145148/dsh-backup'
)

$ErrorActionPreference = 'Stop'

$Here     = $PSScriptRoot
$Inspector = Join-Path $Here 'lib\inspect-sessions.mjs'
$DshHome  = Join-Path $env:USERPROFILE '.dsh'
$Sessions = Join-Path $DshHome 'sessions'
$stamp    = Get-Date -Format 'yyyyMMdd-HHmm'
$logFile  = Join-Path $LocalDir 'backup.log'

New-Item -ItemType Directory -Force -Path $LocalDir | Out-Null

function Log([string]$msg) {
  $line = "[{0}] {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $msg
  Write-Host $line
  Add-Content -Path $logFile -Value $line -Encoding UTF8
}

function Fail([string]$msg) { Log "❌ $msg"; exit 1 }

# 找 Node：优先 DSH 自带的，其次 PATH 里的
function Get-Node {
  $candidates = @(
    (Join-Path $env:USERPROFILE '.dsh\dsh-runtimes\dsh-primary-runtime\dependencies\node\bin\node.exe')
  )
  foreach ($c in $candidates) { if (Test-Path $c) { return $c } }
  $cmd = Get-Command node -ErrorAction SilentlyContinue
  if ($cmd) { return $cmd.Source }
  Fail '找不到 node（DSH 自带的那份也不在预期位置）'
}

function Invoke-Inspect([string]$sessionsDir) {
  $node = Get-Node
  $raw = & $node $Inspector $sessionsDir --json 2>&1
  if ($LASTEXITCODE -ne 0 -and -not $raw) { Fail "会话体检失败：$raw" }
  return ($raw | ConvertFrom-Json)
}

# ---------------- check ----------------
function Do-Check {
  Log "体检 $Sessions"
  $r = Invoke-Inspect $Sessions
  $s = $r.summary
  Log ("会话 {0} 个 | 格式 v{1} | 事件 {2}" -f $s.sessions, ($s.versions -join ',v'), $s.totalEvents)
  Log ("读不了 {0} | seq 断档 {1} | 空会话 {2}" -f $s.unreadable, $s.gaps, $s.empty)

  foreach ($x in $r.results) {
    if (-not $x.ok) { Log ("  ❌ {0}  {1}" -f $x.file, $x.reason) }
    elseif ($x.gaps -gt 0) { Log ("  ⚠️  {0} seq 断档 {1} 处" -f $x.id, $x.gaps) }
  }

  if ($s.unreadable -gt 0 -or $s.gaps -gt 0) { Log '结果：有问题'; exit 1 }
  Log '结果：健康'
}

# ---------------- pack ----------------
function Do-Pack {
  $kind = if ($Full) { 'full' } else { 'core' }

  # ⓪ 「新鲜度」闸门：登录补跑时用，避免一天打好几次
  if ($IfFreshHours -gt 0 -and -not $Full -and -not $Force) {
    $latest = Get-ChildItem $LocalDir -Filter 'dsh-backup-*.tar.gz' -ErrorAction SilentlyContinue |
      Where-Object { $_.Name -notlike 'dsh-backup-full-*' } |
      Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($latest) {
      $hours = ((Get-Date) - $latest.LastWriteTime).TotalHours
      if ($hours -lt $IfFreshHours) {
        Log ("最近一次备份在 {0:N1} 小时前（{1}），不到 {2} 小时，跳过" -f $hours, $latest.Name, $IfFreshHours)
        return
      }
    }
  }

  $prefix = if ($Full) { 'dsh-backup-full-' } else { 'dsh-backup-' }
  $name = "$prefix$stamp.tar.gz"
  $target = Join-Path $LocalDir $name

  # ① 打包前体检
  Log "开始 $kind 备份"
  $pre = Invoke-Inspect $Sessions
  if (($pre.summary.unreadable -gt 0 -or $pre.summary.gaps -gt 0) -and -not $Force) {
    Fail ("会话本身有问题（读不了 {0}、断档 {1}），先跑 check；确实要备份加 -Force" -f $pre.summary.unreadable, $pre.summary.gaps)
  }
  Log ("打包前：{0} 会话 / {1} 事件 / 断档 {2}" -f $pre.summary.sessions, $pre.summary.totalEvents, $pre.summary.gaps)

  # ② 写 manifest
  $manifest = [ordered]@{
    createdAt  = (Get-Date).ToString('o')
    kind       = $kind
    dshHome    = $DshHome
    sessions   = $pre.summary.sessions
    events     = $pre.summary.totalEvents
    versions   = $pre.summary.versions
    gaps       = $pre.summary.gaps
    unreadable = $pre.summary.unreadable
    host       = $env:COMPUTERNAME
    tool       = 'dsh-backup.ps1'
  }
  $manifestPath = Join-Path $env:TEMP "dsh-backup-manifest-$stamp.json"
  [IO.File]::WriteAllText($manifestPath, ($manifest | ConvertTo-Json -Depth 4), (New-Object System.Text.UTF8Encoding($false)))

  # ③ 打包
  $items = @('profiles', 'sessions', 'storages', '.credentials.yaml', '.anonymous-user-id')
  if ($Full) { $items += 'attachments' }
  $present = $items | Where-Object { Test-Path (Join-Path $DshHome $_) }

  $excludes = @(
    '--exclude=profiles/*/node_modules',
    '--exclude=profiles/*/.plugin-manager',
    '--exclude=*/node_modules',
    '--exclude=*.log'
  )
  $stage = Join-Path $env:TEMP "dsh-backup-stage-$stamp"
  New-Item -ItemType Directory -Force -Path $stage | Out-Null
  Copy-Item $manifestPath (Join-Path $stage 'manifest.json') -Force

  # 一次打包：先收 $DshHome 的内容，再把 manifest 从 stage 加进来（-C 可重复）
  $tmpTar = Join-Path $LocalDir ".$name.partial"
  $tarArgs = @('-czf', $tmpTar, '-C', $DshHome) + $excludes + $present + @('-C', $stage, 'manifest.json')
  & tar @tarArgs
  if ($LASTEXITCODE -ne 0) { Remove-Item $tmpTar -Force -ErrorAction SilentlyContinue; Fail "tar 失败（$LASTEXITCODE）" }
  Move-Item $tmpTar $target -Force
if (Test-Path $stage) { Remove-Item $stage -Recurse -Force -ErrorAction SilentlyContinue }
  if ($manifestPath -and (Test-Path $manifestPath)) { Remove-Item $manifestPath -Force -ErrorAction SilentlyContinue }

  $sizeMB = [math]::Round((Get-Item $target).Length / 1MB, 1)
  $entries = @(& tar -tzf $target).Count
  Log "打包完成: $sizeMB MB, $entries 条目"
  if ($entries -lt 10) { Fail "条目数异常（$entries），本次备份作废" }

  # ④ 打包后校验：解回来看是否能读、会话数是否一致
  $verify = Join-Path $env:TEMP "dsh-backup-verify-$stamp"
  New-Item -ItemType Directory -Force -Path $verify | Out-Null
  & tar -xzf $target -C $verify sessions 2>$null
  if (Test-Path (Join-Path $verify 'sessions')) {
    $post = Invoke-Inspect (Join-Path $verify 'sessions')
    if ($post.summary.sessions -ne $pre.summary.sessions) {
      Log ("⚠️ 包内会话数 {0} ≠ 打包前 {1}" -f $post.summary.sessions, $pre.summary.sessions)
    } else {
      Log ("包内校验：{0} 会话 / {1} 事件，与打包前一致 ✅" -f $post.summary.sessions, $post.summary.totalEvents)
    }
    if ($post.summary.unreadable -gt 0) { Log ("⚠️ 包内有 {0} 个会话读不了" -f $post.summary.unreadable) }
  } else {
    Log '⚠️ 包里没解出 sessions/，跳过包内校验'
  }
  Remove-Item $verify -Recurse -Force -ErrorAction SilentlyContinue

  # ⑤ 轮转（两类分开）
  $keep = if ($Full) { $KeepFull } else { $KeepCore }
  $pool = Get-ChildItem $LocalDir -Filter 'dsh-backup-*.tar.gz'
  if ($Full) { $pool = $pool | Where-Object { $_.Name -like 'dsh-backup-full-*' } }
  else       { $pool = $pool | Where-Object { $_.Name -notlike 'dsh-backup-full-*' } }
  $old = $pool | Sort-Object LastWriteTime -Descending | Select-Object -Skip $keep
  foreach ($f in $old) { Remove-Item $f.FullName -Force; Log "清理旧备份: $($f.Name)" }

  # ⑥ 上传
  if ($Full) { Log '完整备份不上传（体积大），只留本地'; return }
  if ($NoUpload) { Log '指定了 -NoUpload，跳过上传'; return }
  Upload-Backup -Path $target -Name $name
}

# ---------------- 上传 ----------------
function Get-Token {
  if ($env:GH_TOKEN) { return $env:GH_TOKEN }
  $tf = Join-Path $env:USERPROFILE '.dsh-backup-token'
  if (Test-Path $tf) { return (Get-Content $tf -Raw).Trim() }
  return $null
}

function Upload-Backup([string]$Path, [string]$Name) {
  $token = Get-Token
  if (-not $token) { Log '没有令牌（GH_TOKEN 或 %USERPROFILE%\.dsh-backup-token），跳过上传'; return }

  $headers = @{
    Authorization = "Bearer $token"
    'User-Agent'  = 'dsh-backup'
    Accept        = 'application/vnd.github+json'
  }

  $tag = 'auto-' + (Get-Date -Format 'yyyy-MM-dd')
  try {
    $release = $null
    try { $release = Invoke-RestMethod -Uri "https://api.github.com/repos/$Repo/releases/tags/$tag" -Headers $headers -TimeoutSec 30 } catch { }

    if (-not $release) {
      $body = @{ tag_name = $tag; name = "自动备份 $((Get-Date).ToString('yyyy-MM-dd'))"; draft = $false; prerelease = $false } | ConvertTo-Json
      $release = Invoke-RestMethod -Uri "https://api.github.com/repos/$Repo/releases" -Method POST -Headers $headers `
        -Body ([Text.Encoding]::UTF8.GetBytes($body)) -ContentType 'application/json' -TimeoutSec 60
      Log "新建 Release: $tag"
    } else { Log "复用 Release: $tag" }

    $uploadUrl = ($release.upload_url -replace '\{\?name,label\}', '') + "?name=$Name"
    $bytes = [IO.File]::ReadAllBytes($Path)
    $up = $headers.Clone(); $up['Content-Type'] = 'application/gzip'

    $ok = $false
    for ($i = 1; $i -le 3 -and -not $ok; $i++) {
      try {
        $asset = Invoke-RestMethod -Uri $uploadUrl -Method POST -Headers $up -Body $bytes -TimeoutSec 900
        Log ("上传成功: {0} ({1:N1} MB)" -f $asset.name, ($asset.size / 1MB))
        $ok = $true
      } catch {
        Log ("第 {0} 次上传失败: {1}" -f $i, $_.Exception.Message)
        Start-Sleep -Seconds (5 * $i)
      }
    }
    if (-not $ok) { Fail '上传三次都失败（本地备份已保留）' }

    $all = Invoke-RestMethod -Uri "https://api.github.com/repos/$Repo/releases?per_page=100" -Headers $headers -TimeoutSec 30
    $stale = $all | Where-Object { $_.tag_name -like 'auto-*' } | Sort-Object created_at -Descending | Select-Object -Skip $KeepReleases
    foreach ($r in $stale) {
      Invoke-RestMethod -Uri "https://api.github.com/repos/$Repo/releases/$($r.id)" -Method DELETE -Headers $headers -TimeoutSec 30
      Log "清理旧 Release: $($r.tag_name)"
    }
  } catch {
    Fail "上传出错: $($_.Exception.Message)"
  }
}

# ---------------- list ----------------
function Do-List {
  Write-Host "本地备份 ($LocalDir)：" -ForegroundColor Cyan
  Get-ChildItem $LocalDir -Filter 'dsh-backup-*.tar.gz' -ErrorAction SilentlyContinue |
    Sort-Object LastWriteTime -Descending |
    Select-Object -First 10 @{n='大小MB';e={[math]::Round($_.Length/1MB,1)}},LastWriteTime,Name |
    Format-Table -AutoSize

  $token = Get-Token
  if (-not $token) { return }
  Write-Host "云端 Release：" -ForegroundColor Cyan
  try {
    $headers = @{ Authorization = "Bearer $token"; 'User-Agent' = 'dsh-backup'; Accept = 'application/vnd.github+json' }
    $rels = Invoke-RestMethod -Uri "https://api.github.com/repos/$Repo/releases?per_page=20" -Headers $headers -TimeoutSec 30
    $rels | Where-Object { $_.tag_name -like 'auto-*' } | Select-Object -First 10 | ForEach-Object {
      $asset = $_.assets | Select-Object -First 1
      Write-Host ("  {0}  {1}  {2:N1} MB" -f $_.tag_name, $_.created_at, (($asset.size) / 1MB))
    }
  } catch { Write-Host "  读取失败: $($_.Exception.Message)" }
}

# ---------------- restore ----------------
function Do-Restore([string]$file) {
  if (-not $file) { Fail '用法: .\dsh-backup.ps1 restore <备份包路径>' }
  if (-not (Test-Path $file)) { Fail "找不到文件: $file" }

  if (Get-Process -Name 'DeepSeek Harness' -ErrorAction SilentlyContinue) {
    if (-not $Force) { Fail 'DSH 正在运行，先退出再还原（确认要强来加 -Force）' }
    Log '⚠️ DSH 在运行，按 -Force 继续'
  }

  $stage = Join-Path $env:TEMP ("dsh-restore-" + (Get-Date -Format 'yyyyMMdd-HHmmss'))
  New-Item -ItemType Directory -Force -Path $stage | Out-Null
  Log "解到临时目录: $stage"
  & tar -xzf $file -C $stage
  if ($LASTEXITCODE -ne 0) { Fail '解包失败' }

  if (Test-Path (Join-Path $stage 'sessions')) {
    $r = Invoke-Inspect (Join-Path $stage 'sessions')
    Log ("包内会话 {0} 个 / 事件 {1} / 断档 {2}" -f $r.summary.sessions, $r.summary.totalEvents, $r.summary.gaps)
    if ($r.summary.unreadable -gt 0) { Fail '包里有读不了的会话，放弃还原' }
  }

  Log "覆盖到 $DshHome …"
  Get-ChildItem $stage | ForEach-Object {
    Copy-Item $_.FullName $DshHome -Recurse -Force
  }
  Remove-Item $stage -Recurse -Force -ErrorAction SilentlyContinue
  Log '还原完成。启动 DSH 后如果对话列表异常，跑一次 dsh-reindex。'
}

# ---------------- 只备份 attachments ----------------
function Do-PackAttachments {
  $src = Join-Path $DshHome 'attachments'
  if (-not (Test-Path $src)) { Fail '没有 attachments 目录' }

  $month = Get-Date -Format 'yyyy-MM'
  $existing = Get-ChildItem $LocalDir -Filter "dsh-attachments-$month-*.tar.gz" -ErrorAction SilentlyContinue
  if ($existing -and -not $Force) {
    Log ("本月已有附件备份: {0}（要重做加 -Force）" -f $existing[0].Name)
    return
  }

  $name = "dsh-attachments-$month-" + (Get-Date -Format 'ddHHmm') + '.tar.gz'
  $target = Join-Path $LocalDir $name

  $sum = Get-ChildItem $src -Recurse -File | Measure-Object Length -Sum
  Log ("开始附件备份: {0} 个文件 / {1:N1} MB" -f $sum.Count, ($sum.Sum / 1MB))

  & tar -czf $target -C $DshHome attachments
  if ($LASTEXITCODE -ne 0) { Remove-Item $target -Force -ErrorAction SilentlyContinue; Fail "tar 失败（$LASTEXITCODE）" }

  $entries = @(& tar -tzf $target).Count
  $sizeMB = [math]::Round((Get-Item $target).Length / 1MB, 1)
  Log "完成: $sizeMB MB, $entries 条目"
  if ($entries -lt 2) { Fail "条目异常（$entries），本次作废" }

  $old = Get-ChildItem $LocalDir -Filter 'dsh-attachments-*.tar.gz' |
    Sort-Object LastWriteTime -Descending | Select-Object -Skip $KeepAttach
  foreach ($f in $old) { Remove-Item $f.FullName -Force; Log "清理旧附件备份: $($f.Name)" }

  if ($NoUpload -or -not $Upload) {
    Log '附件备份默认不上传（体积大，占 Release 存储）；确实要传加 -Upload'
    return
  }
  Upload-Backup -Path $target -Name $name
}

switch ($Command.ToLower()) {
  'check'   { Do-Check }
  'pack'    { if ($AttachmentsOnly) { Do-PackAttachments } else { Do-Pack } }
  'list'    { Do-List }
  'restore' { Do-Restore $Target }
  default   {
    Write-Host "用法:"
    Write-Host "  .\dsh-backup.ps1 check"
    Write-Host "  .\dsh-backup.ps1 pack [-Full] [-NoUpload] [-Force]"
    Write-Host "  .\dsh-backup.ps1 pack -AttachmentsOnly     # 只备份 attachments（每月一份）"
    Write-Host "  .\dsh-backup.ps1 list"
    Write-Host "  .\dsh-backup.ps1 restore <包路径>"
  }
}
