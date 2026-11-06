# 注册「DSH 自动备份」计划任务
#
#   DSH-AutoBackup-Core     每天 03:30     核心备份（19 MB）+ 上传私有 Release
#   DSH-AutoBackup-Full     每周日 04:00   完整备份（约 340 MB）+ 只留本地
#   DSH-AutoBackup-Attach   每月 1 日 04:30 只备份 attachments（约 243 MB，留 12 份）
#
# 用法：
#   .\setup-task.ps1            # 注册（建议管理员身份跑一次）
#   .\setup-task.ps1 -RunNow    # 注册后立刻跑一次核心备份
#   .\setup-task.ps1 -Remove    # 移除

param(
  [switch]$Remove,
  [switch]$RunNow
)

$ErrorActionPreference = 'Stop'
$script = Join-Path $PSScriptRoot 'dsh-backup.ps1'
if (-not (Test-Path $script)) { throw "找不到 $script" }

$coreTask = 'DSH-AutoBackup-Core'
$fullTask = 'DSH-AutoBackup-Full'
$attachTask = 'DSH-AutoBackup-Attach'

if ($Remove) {
  foreach ($n in @($coreTask, $fullTask, $attachTask)) {
    if (Get-ScheduledTask -TaskName $n -ErrorAction SilentlyContinue) {
      Unregister-ScheduledTask -TaskName $n -Confirm:$false
      Write-Host "已移除任务: $n"
    }
  }
  return
}

function New-BackupTask {
  param([string]$Name, [string]$Time, [string]$Args, [string]$Description, [string]$DayOfWeek, [switch]$Monthly)

  $action = New-ScheduledTaskAction -Execute 'powershell.exe' `
    -Argument ("-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"{0}`" {1}" -f $script, $Args)

  # 附件备份用「每天触发 + 脚本内按月去重」实现每月一次：
  #   New-ScheduledTaskTrigger 不支持 -Monthly，schtasks 又需要提权，
  #   而 Do-PackAttachments 本身会检查「本月是否已有备份」，重复触发是空操作。
  if ($DayOfWeek) { $trigger = New-ScheduledTaskTrigger -Weekly -DaysOfWeek $DayOfWeek -At $Time }
  else            { $trigger = New-ScheduledTaskTrigger -Daily -At $Time }

  $settings = New-ScheduledTaskSettingsSet `
    -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
    -ExecutionTimeLimit (New-TimeSpan -Hours 2) -MultipleInstances IgnoreNew

  if (Get-ScheduledTask -TaskName $Name -ErrorAction SilentlyContinue) {
    Unregister-ScheduledTask -TaskName $Name -Confirm:$false
  }
  Register-ScheduledTask -TaskName $Name -Action $action -Trigger $trigger -Settings $settings -Description $Description | Out-Null
  Write-Host "已注册: $Name  ($Description)"
}

New-BackupTask -Name $coreTask -Time '03:30' -Args 'pack' -Description 'DSH 每日核心备份并上传私有 Release'
New-BackupTask -Name $fullTask -Time '04:00' -Args 'pack -Full' -DayOfWeek 'Sunday' -Description 'DSH 每周完整备份（含 attachments），只留本地'
New-BackupTask -Name $attachTask -Time '04:30' -Args 'pack -AttachmentsOnly' -Description 'DSH 附件备份（每月真正执行一次，脚本内去重），保留 12 份'

Write-Host ""
Write-Host "查看:" -ForegroundColor Cyan
Write-Host "  Get-ScheduledTask -TaskName 'DSH-AutoBackup-*' | Select TaskName,State"
Write-Host "  Get-ScheduledTaskInfo -TaskName 'DSH-AutoBackup-Core'"
Write-Host "日志: D:\Backup\dsh-backups\backup.log"

if ($RunNow) { & powershell -NoProfile -ExecutionPolicy Bypass -File $script pack }