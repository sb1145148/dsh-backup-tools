# dsh-backup-tools

给 **DeepSeek Harness（DSH）** 在 Windows 上做**带校验的自动备份**。

灵感来自 [dsh-tools](https://github.com/sb1145148/dsh-tools) 的 `dsh-backup`，做成了独立工具，
并补上了它没有的一步：**打包后把包解开再体检一遍**。

> 这是开源的工具本体。备份文件本身会传到**你自己指定的私有仓库**（见下面「配置你自己的备份仓库」），不进这个仓库。

## 一键安装

PowerShell 里跑这一行（会下载到 `%USERPROFILE%\dsh-backup-tools` 并自检）：

```powershell
iex ((irm https://raw.githubusercontent.com/sb1145148/dsh-backup-tools/main/install.ps1).TrimStart([char]0xFEFF))
```

**装完自动注册计划任务**：

```powershell
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/sb1145148/dsh-backup-tools/main/install.ps1).TrimStart([char]0xFEFF))) -Register
```

> **为什么要有 `.TrimStart([char]0xFEFF)`**：PowerShell 5.1 的 `irm` 会把 UTF-8 响应解成带 BOM 的字符串，
> 而 `iex` 遇到开头的 BOM 会报「无法将 `﻿Write-Host` 项识别为 cmdlet」。这一句把 BOM 去掉。
>
> 嫌长就下载后跑：`.\install.ps1 -Dir D:\Tools\dsh-backup-tools -Register`

安装脚本做的事：

1. 从 `codeload.github.com` 下 zip（失败则逐个拉 raw 文件）
2. 解到目标目录，清掉 `.git`
3. 跑一次 `check` 自检（`-NoVerify` 可跳过）
4. `-Register` 时调用 `setup-task.ps1` 注册三个计划任务

## 手动安装

```powershell
git clone https://github.com/sb1145148/dsh-backup-tools
cd dsh-backup-tools
.\dsh-backup.ps1 check
```

## 它比原版多做了什么

| 能力 | dsh-tools 的 dsh-backup | 这个工具 |
| --- | --- | --- |
| 打包 | ✅ | ✅ |
| 会话 seq 连续性检查 | ✅（打包前） | ✅（**打包前 + 打包后各一次**） |
| 包里写清单 | 环境信息 | `manifest.json`（会话数 / 事件数 / seq 统计 / 主机） |
| 轮转 | 按类型 | 核心与完整分开算，不会互相挤掉 |
| 上传云端 | ❌ | ✅ 私有 Release，自动清理旧版本 |
| 还原前校验 | ⚠️ 仅提示 | ✅ 先解到临时目录体检，通过才覆盖 |
| 依赖 | bash + python3 + libzstd | **只要 Windows PowerShell + 自带 Node** |

**不需要 Git Bash，也不需要 Python**：解压会话用的是 Node 24 内置的 zstd。

## 子命令

```powershell
.\dsh-backup.ps1 check                    # 体检：格式 / seq 断档 / 空会话
.\dsh-backup.ps1 pack                     # 打包 + 校验 + 轮转 + 上传
.\dsh-backup.ps1 pack -NoUpload           # 只留本地
.\dsh-backup.ps1 pack -Full               # 连 attachments（只留本地）
.\dsh-backup.ps1 pack -AttachmentsOnly    # 只备份附件（每月一份，留 12 份）
.\dsh-backup.ps1 pack -Force              # 会话有问题也强行打包
.\dsh-backup.ps1 list                     # 本地 + 云端清单
.\dsh-backup.ps1 restore <包> [-Force]    # 还原（先校验再覆盖）
```

## 备份策略

| 类型 | 内容 | 大小 | 本地 | 云端 |
| --- | --- | --- | --- | --- |
| **核心**（默认） | `profiles/` `sessions/` `storages/` 凭据 | ~19 MB | 留 7 份 | ✅ Release |
| **完整**（`-Full`） | 核心 + `attachments/` | ~340 MB | 留 3 份 | ❌ 太大 |
| **附件**（`-AttachmentsOnly`） | 只 `attachments/` | ~243 MB | **留 12 份** | 默认不上传 |

### 为什么单独备份附件

附件（对话里的图片和上传的文件）是**唯一"丢就找不回"**的东西：

- 会话文字在 `sessions/` 里，核心备份每天有
- 但附件按 sha256 存在 `attachments/`，**不在核心备份里**

完整备份虽然含附件，但只留 3 份——三周后最早的就被轮转删掉，里面的图片永久消失。

`-AttachmentsOnly` 解决这个：**每月一份，保留 12 份**，只花 243 MB × 12。

脚本内做月度去重：同一个月重复触发会直接跳过（`-Force` 强制重做）。

```powershell
.\dsh-backup.ps1 pack -AttachmentsOnly          # 本月第一次会打包，之后跳过
.\dsh-backup.ps1 pack -AttachmentsOnly -Force   # 强制重做
```

附件备份**默认不上传**（体积大）。要传加 `-Upload`。

## 配置你自己的备份仓库

工具默认把备份传到 `sb1145148/dsh-backup`，**请改成你自己的私有仓库**：

```powershell
# 方式一：命令行参数
.\dsh-backup.ps1 pack -Repo "你的用户名/你的备份仓库"

# 方式二：改脚本顶部的默认值
# [string]$Repo = '你的用户名/你的备份仓库'
```

**备份仓库必须是私有的**——备份包里含 `profiles/` 和 `.credentials.yaml`，等同于账号凭据。

令牌只需要对一个仓库的 `Contents: Read and write` 权限。

## 自动运行

```powershell
# 1) 令牌（只放本机，别提交）
Set-Content -Path "$env:USERPROFILE\.dsh-backup-token" -Value "github_pat_xxx" -NoNewline

# 2) 注册计划任务（建议管理员身份跑一次）
.\setup-task.ps1

# 3) 立刻跑一次验证
.\setup-task.ps1 -RunNow
```

| 任务 | 时间 | 命令 |
| --- | --- | --- |
| `DSH-AutoBackup-Core` | 每天 03:30 **+ 登录后 3 分钟** | `pack -IfFreshHours 8` |
| `DSH-AutoBackup-Full` | 每周日 04:00 | `pack -Full` |
| `DSH-AutoBackup-Attach` | 每天 04:30（脚本内按月去重） | `pack -AttachmentsOnly` |

三个任务都开了 `StartWhenAvailable`：关机错过，开机后补跑。

**核心备份还额外挂了一个「登录触发」**（延迟 3 分钟）：晚上不开机、白天才开也能当天备份上。

配合 `-IfFreshHours 8`：8 小时内已经备份过就直接跳过，不会一天打好几份。

```powershell
.\dsh-backup.ps1 pack -IfFreshHours 8    # 8 小时内备份过就跳过
```

## 校验到底校了什么

```
打包前  → node lib/inspect-sessions.mjs  得到：26 会话 / 41996 事件 / 断档 0
打包    → tar（含 manifest.json）
打包后  → 解回 sessions/ 再跑一次 inspect
        → 会话数、事件数必须与打包前一致
```

实测输出：

```
[00:51:56] 打包前：26 会话 / 41996 事件 / 断档 0
[00:51:57] 打包完成: 19.7 MB, 96 条目
[00:51:59] 包内校验：26 会话 / 41996 事件，与打包前一致 ✅
```

**这一步能抓到的最坏情况**：tar 报成功但内容不全、会话文件正在被写导致撕裂。

## 状态码 / 行为

| 情况 | 行为 |
| --- | --- |
| 会话有断档或读不了 | **打包前就停**（除非 `-Force`） |
| 包内会话数与打包前不一致 | 记警告，仍保留（本地备份优先） |
| 没有令牌 | 跳过上传，本地照常 |
| 上传失败 | 重试 3 次（间隔递增），失败则退出码 1 |

**原则：本地备份永远先成立，云端只是第二份。**

## 怎么验证它真的在工作

**装完不等于在跑。** 下面是实测通过的检查流程（2026-11-08 验证）。

### ① 先看任务参数对不对

```powershell
Get-ScheduledTask -TaskName 'DSH-AutoBackup-*' |
  ForEach-Object {
    "{0}`n  {1}" -f $_.TaskName, ($_.Actions | Select-Object -First 1).Arguments
  }
```

**参数里必须带子命令：**

```text
DSH-AutoBackup-Core    ... dsh-backup.ps1 pack -IfFreshHours 8
DSH-AutoBackup-Full    ... dsh-backup.ps1 pack -Full
DSH-AutoBackup-Attach  ... dsh-backup.ps1 pack -AttachmentsOnly
```

**如果参数在脚本路径后面就断了，说明只跑 `check`（默认子命令），不会备份。**

> 我们踩过：`setup-task.ps1` 里参数名写成 `$Args`，而 `$Args` 是 PowerShell 的自动变量，
> 函数内会被覆盖成空 → 三个任务全都只跑 `check`，日志显示的是「体检…结果：健康」。

### ② 手动触发一次

```powershell
Start-ScheduledTask -TaskName 'DSH-AutoBackup-Core'
# 等 15-20 秒，看日志
Get-Content D:\Backup\dsh-backups\backup.log -Tail 8
```

**成功的日志长这样：**

```text
[03:21:03] 开始 core 备份
[03:21:05] 打包前：26 会话 / 44134 事件 / 断档 0
[03:21:06] 打包完成: 21.1 MB, 96 条目
[03:21:10] 包内校验：26 会话 / 44134 事件，与打包前一致 ✅
[03:21:10] 清理旧备份: dsh-backup-20261107-0031.tar.gz
[03:21:11] 上传成功: dsh-backup-20261108-0321.tar.gz (21.1 MB)
```

**看到「开始 core 备份」才是真跑了。看到「体检」说明参数没传进去。**

### ③ 三个地方都要对上

| 查什么 | 命令 | 期望 |
| --- | --- | --- |
| 本地文件 | `Get-ChildItem D:\Backup\dsh-backups\*.tar.gz` | 最新一份是刚才的时间 |
| 包内清单 | `tar -xzOf <包> manifest.json` | `sessions` / `events` 与日志一致 |
| 云端 | `.\dsh-backup.ps1 list` | 有对应日期的 Release |

### ④ 常见现象对照

| 现象 | 含义 | 处理 |
| --- | --- | --- |
| 日志只有「体检…结果：健康」 | 任务参数没传进去 | 重跑 `setup-task.ps1`，检查参数 |
| 「最近一次备份在 X 小时前，跳过」 | 新鲜度闸门生效（`-IfFreshHours 8`） | 正常，不是故障 |
| 「❌ 上传出错: 401」 | 令牌失效 | 换令牌（见下节） |
| 「跳过上传」 | 没有令牌 | 写 `%USERPROFILE%\.dsh-backup-token` |
| 任务结果码 `0` | 成功 | — |
| 任务结果码 `1` | 有一步失败（通常是上传） | 看日志最后一行 |

### ⑤ 令牌自查

```powershell
$t = (Get-Content "$env:USERPROFILE\.dsh-backup-token" -Raw).Trim()
"长度: $($t.Length)  前缀: $($t.Substring(0,16))…"
```

**用 PowerShell 测有效性（不要用 curl）：**

```powershell
Invoke-RestMethod -Uri 'https://api.github.com/user' `
  -Headers @{ Authorization = "Bearer $t"; 'User-Agent' = 'dsh-backup' } |
  Select-Object login
```

**两种失败要分清：**

```text
401 Bad credentials   → 令牌无效/被吊销
000（curl 返回 000）   → 根本没连上，是网络问题，不是令牌问题
```

> 这个环境里 `curl` 访问 `api.github.com` 会返回 `000`，但 PowerShell 的
> `Invoke-RestMethod` 正常。**备份脚本用的正是后者**，所以能用 curl 测出 000 不代表令牌坏了。

### ⑥ 令牌过期前要换

**令牌设了有效期，到期后备份会静默开始报 401。**

**建议在日历上标一下到期日**，或定期看 `list` 里最近一个 Release 是哪天：

```powershell
.\dsh-backup.ps1 list
```

**如果最近备份是很久以前，说明链路上某一环断了。**

## 还原

```powershell
# 先退出 DSH！
.\dsh-backup.ps1 restore D:\Backup\dsh-backups\dsh-backup-20261107-0052.tar.gz
```

流程：解到临时目录 → 体检（读不了就中止）→ 覆盖到 `%USERPROFILE%\.dsh`。

**DSH 在跑时默认拒绝还原**，除非 `-Force`。

还原后如果对话列表异常，跑一次 `dsh-reindex` 重建工作区索引。

## 文件

| 文件 | 作用 |
| --- | --- |
| `install.ps1` | 一键安装（下载 → 落位 → 自检 → 可选注册任务） |
| `dsh-backup.ps1` | 主程序（check / pack / list / restore） |
| `lib/inspect-sessions.mjs` | 会话解析：按 zstd 帧切分，统计 seq 断档 |
| `setup-task.ps1` | 注册 / 移除计划任务 |

## 依赖

- **PowerShell 5.1**（Windows 自带）
- **Node 24+**：DSH 自带的就够（`~/.dsh/dsh-runtimes/*/dependencies/node/bin/node.exe`）

不需要 Python、不需要 Git Bash、不需要 zstd 命令。

## 已知限制

- 只在 Windows + DSH 桌面版（0.2.2-rc.1）上验证
- `attachments/` 不在核心备份里：丢的是对话里的图片，不是文字记录
- 会话文件是「两个 zstd 帧」，解析器按魔数切分；极端情况会合并重试，但**不支持 v5 格式**

## 许可

MIT（见[LICENSE](LICENSE))
