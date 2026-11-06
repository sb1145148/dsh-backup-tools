# dsh-backup-tools

给 **DeepSeek Harness（DSH）** 在 Windows 上做**带校验的自动备份**。

灵感来自 [dsh-tools](https://github.com/sb1145148/dsh-tools) 的 `dsh-backup`，做成了独立工具，
并补上了它没有的一步：**打包后把包解开再体检一遍**。

> 这是开源的工具本体。备份文件本身会传到**你自己指定的私有仓库**（见下面「配置你自己的备份仓库」），不进这个仓库。

## 一键安装

PowerShell 里跑这一行（会下载到 `%USERPROFILE%\dsh-backup-tools` 并自检）：

```powershell
iex ([Text.Encoding]::UTF8.GetString((irm https://raw.githubusercontent.com/sb1145148/dsh-backup-tools/main/install.ps1).Content))
```

**装完自动注册计划任务**：

```powershell
iex ([Text.Encoding]::UTF8.GetString((irm https://raw.githubusercontent.com/sb1145148/dsh-backup-tools/main/install.ps1).Content)) -Register
```

> `irm` 单独用会把中文解码错，所以外面套了 `[Text.Encoding]::UTF8.GetString(...)`。
> 嫌长可以直接下载 `install.ps1` 再跑：`.\install.ps1 -Dir D:\Tools\dsh-backup-tools -Register`

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
| `DSH-AutoBackup-Core` | 每天 03:30 | `pack` |
| `DSH-AutoBackup-Full` | 每周日 04:00 | `pack -Full` |
| `DSH-AutoBackup-Attach` | 每天 04:30（脚本内按月去重） | `pack -AttachmentsOnly` |

两个任务都开了 `StartWhenAvailable`：关机错过，开机后补跑。

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

MIT
