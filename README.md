# Our Free Model 一键安装脚本（Windows）

> 在**已经装好 DeepSeek Harness 的 Windows 电脑**上，双击一次即可安装
> [Ebony-Vinyl/dsh-our-free-model](https://github.com/Ebony-Vinyl/dsh-our-free-model) 插件，
> 无需手动下载、解压、改配置。

本仓库：<https://github.com/starrynight-wq/dsh-our-free-model-script>

---

## 目录

- [特性](#特性)
- [前置条件](#前置条件)
- [快速开始](#快速开始)
- [工作原理](#工作原理)
- [命令行参数](#命令行参数)
- [安装之后](#安装之后)
- [更新与卸载](#更新与卸载)
- [常见问题](#常见问题)
- [安全与合规](#安全与合规)
- [实测记录](#实测记录)
- [目录结构](#目录结构)
- [版本记录](#版本记录)
- [反馈与免责](#反馈与免责)

---

## 特性

| 特性 | 说明 |
| --- | --- |
| **一键安装** | 双击 `一键安装 Our Free Model.cmd` 即可，全程中文提示。 |
| **官方来源 + 强校验** | 只从 GitHub 官方 Release 下载 `dsh-our-free-model-<版本>.tgz`，并用官方 `SHA256SUMS` 做 **SHA-256 校验**。 |
| **不依赖 Node.js / pnpm** | 调用 DeepSeek Harness 自带的 `dsh` CLI（使用内置 pnpm）完成安装，与「设置 → 插件 → 添加插件」是同一条官方安装路径；系统无需安装任何运行时。 |
| **自动探测环境** | 自动定位 DSH 数据目录、桌面端安装目录（进程 / 注册表 / 常见目录）与目标 profile。 |
| **幂等、可更新** | 已安装同版本时自动跳过；有新版本时再次双击即升级。 |
| **可卸载** | 双击 `一键卸载 Our Free Model.cmd` 即可移除插件（保留插件数据）。 |
| **可离线** | 手动下载 `.tgz` 后用 `-Tarball` 指定，仍会做 SHA-256 校验。 |
| **可预览** | `-DryRun` 只检测环境并打印将要执行的操作，不做任何修改。 |
| **日志** | 每次运行自动保存日志到 `%TEMP%\our-free-model-install-<时间>.log`。 |

---

## 前置条件

1. Windows 10 1803+ 或 Windows 11（脚本使用系统自带的 `tar.exe` 做包检查）。
2. 已安装 DeepSeek Harness，并且**至少启动过一次**（桌面端会初始化
   `%USERPROFILE%\.dsh\profiles\desktop`）。
3. 网络可访问 GitHub（下载插件包与校验文件）；访问不畅时可用离线方式。
4. 系统自带的 **Windows PowerShell 5.1** 即可，不需要管理员权限。

> 桌面端安装目录不是标准位置也能用：脚本会依次尝试
> `-AppDir` 参数 → 正在运行的桌面端进程 → 注册表卸载项 → 常见安装目录。

---

## 快速开始

| 操作 | 做法 |
| --- | --- |
| **安装 / 更新** | 双击 **`一键安装 Our Free Model.cmd`** |
| **卸载** | 双击 **`一键卸载 Our Free Model.cmd`** |

安装完成后：**完全退出** DeepSeek Harness（右键任务栏托盘图标 → 退出；只关窗口不算），
再重新启动；打开 **设置 → Our Free Model**（首次进入有 5 页公告），
在对话框的模型选择器里即可选择免费模型，无需登录、注册或填 API Key。

> 第一步建议先跑一次只检测、不修改的预览：
>
> ```powershell
> powershell -NoProfile -ExecutionPolicy Bypass -File .\install-our-free-model.ps1 -DryRun
> ```

---

## 工作原理

脚本执行以下步骤：

1. **探测环境**
   - DSH 数据目录：`-DshHome` → 环境变量 `DSH_HOME` → 默认 `%USERPROFILE%\.dsh`；
   - 目标 profile：`-Profile` → 环境变量 `DSH_PROFILE` → 桌面端 `desktop`（或磁盘上唯一的 profile）→ `web`；
   - `dsh` CLI：优先使用 PATH 中的 `dsh`，否则使用桌面端
     `resources\runtime\cli\bin\dsh.cmd`（后者内置 pnpm）。
2. **确定版本**：通过 GitHub Releases API 获取最新**正式版**（排除 draft / prerelease
   与 `-macos-unofficial` 之类社区构建），也可用 `-Version` 指定。
3. **下载并校验**：下载插件包与 `SHA256SUMS`，比对 SHA-256；通过后缓存到
   `<profile 目录>\vendor\dsh-our-free-model-<版本>.tgz`
   （与插件 README 推荐的本地 tarball 位置一致，后续 pnpm 解析依赖也能用到）。
4. **安装**：执行

   ```powershell
   dsh plugin --profile <profile> add <插件包路径>
   ```

   由 DSH 官方 CLI 使用内置 pnpm 完成依赖安装、bundle 注册与兼容性检查。
5. **安装后检查**：确认 profile 的 `package.json` 中依赖已写入、
   `dsh.profile.bundles` 已包含 `dsh-our-free-model`、`node_modules\dsh-our-free-model`
   的文件完整。
6. **输出指引**：重启方式、设置页入口、插件数据目录位置。

全程只写 DSH profile 目录与 `%TEMP%`；不会修改 DSH 内核，也不会往插件目录之外散布文件。

### 等价手动命令（不使用脚本时）

```powershell
# 1) 从 Release 页面下载 dsh-our-free-model-<版本>.tgz 与 SHA256SUMS，并核对 SHA-256
# 2) 用桌面端自带的 dsh CLI 安装（--profile 填实际 profile，桌面端为 desktop）
& "D:\DeepSeek Harness\resources\runtime\cli\bin\dsh.cmd" `
    plugin --profile desktop add "C:\path\to\dsh-our-free-model-2.8.9.tgz"
# 3) 完全退出并重启 DeepSeek Harness
```

---

## 命令行参数

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\install-our-free-model.ps1 [参数]
```

| 参数 | 说明 |
| --- | --- |
| `-Profile <名称>` | DSH profile 名称。默认：优先取环境变量 `DSH_PROFILE`；其次若发现桌面端且数据目录中已有 `desktop` profile（或尚无任何 profile）用 `desktop`；否则取磁盘上唯一的 profile，最后退回 `desktop`/`web`。 |
| `-DshHome <目录>` | DSH 数据目录。默认：环境变量 `DSH_HOME`，否则 `%USERPROFILE%\.dsh`。 |
| `-Version <X.Y.Z>` | 指定插件版本，默认取 GitHub 最新正式版。 |
| `-Tarball <路径>` | 使用本地 `.tgz` 插件包（离线 / 手动下载）。仍会尽量做 SHA-256 校验。 |
| `-AppDir <目录>` | 手动指定 DeepSeek Harness 安装目录（应包含 `resources\runtime\cli\bin\dsh.cmd`）。 |
| `-Uninstall` | 卸载插件（保留插件数据目录与插件包缓存）。 |
| `-Force` | 已安装同版本时强制重装；版本不同时总是升级/降级到目标版本。 |
| `-SkipChecksum` | 跳过 SHA-256 校验。**不安全**，仅在确认来源可信时使用。 |
| `-DryRun` | 只检测环境并打印将要执行的操作，不做任何修改。 |

退出码：`0` 成功；`1` 失败（输出中会给出中文原因与处理建议）。

---

## 安装之后

- **设置页入口**：设置 → **Our Free Model**（免费模型、数据看板、运行日志、渠道、网关等页面）。
- **模型选择器**：免费模型会出现在模型列表里，选中后直接对话即可，无需账号或 API Key。
- **插件数据目录**：`%USERPROFILE%\.dsh\our-free-model`（用量、设置、会话映射等），**卸载不会删除**。
- **插件包缓存**：`<profile 目录>\vendor\dsh-our-free-model-<版本>.tgz`。

> 本环境下插件由 profile 的 pnpm 依赖管理，因此插件自带的「应用内一键升级」会主动拒绝
> （避免与 pnpm 双写入损坏安装）。升级请使用本脚本，或「设置 → 插件」。

---

## 更新与卸载

- **更新插件**：重新双击安装脚本即可升级到最新正式版；也可指定版本：
  `-Version 2.8.9`。
- **更新脚本本身**：`git pull` 本仓库后再次运行即可。
- **卸载插件**：双击卸载脚本，或
  `powershell -NoProfile -ExecutionPolicy Bypass -File .\install-our-free-model.ps1 -Uninstall`。
  卸载不会删除插件数据目录；如需彻底清理，手动删除
  `%USERPROFILE%\.dsh\our-free-model` 与 profile 下 `vendor\` 中的插件包。

---

## 常见问题

**1. 提示「没有找到 DeepSeek Harness」**
- 用 `-AppDir "D:\你的安装目录"` 指定；目录中应有 `resources\runtime\cli\bin\dsh.cmd`。
- 或确认已安装并至少启动过一次。

**2. 提示「桌面端 profile 尚未初始化」**
- 先启动一次 DeepSeek Harness，完全退出，再运行脚本。

**3. GitHub 下载很慢或失败**
- 手动从 <https://github.com/Ebony-Vinyl/dsh-our-free-model/releases> 下载
  `dsh-our-free-model-<版本>.tgz`，再用 `-Tarball` 指定；脚本会继续尝试用官方
  `SHA256SUMS` 校验（校验值仍从 GitHub 获取；若 GitHub 完全不可达，才需要
  `-SkipChecksum`）。
- 脚本走系统代理设置；公司网络需要代理时，先在 Windows「设置 → 网络和 Internet → 代理」
  配置，或使用离线方式。

**4. 提示 SHA-256 校验失败**
- 说明文件下载不完整或被替换。请删除 `<profile>\vendor\` 下对应的 `.tgz` 后重试，
  或手动核对官方 `SHA256SUMS`。

**5. 安装命令失败（dsh / pnpm 报错）**
- 输出里的 `[WARN] Issues with peer dependencies found` 属于正常现象（插件自身的
  peer 声明用于兼容性检查，运行时不需要额外依赖）。
- 详细日志在 `<profile 目录>\.plugin-manager\logs\`。
- 若是 profile 的 pnpm 状态过旧（例如 `ERR_PNPM_VIRTUAL_STORE_DIR_MAX_LENGTH_DIFF`），
  关闭 DSH、删除该 profile 的 `node_modules` 与 `pnpm-lock.yaml` 后重试。

**6. 提示已用 npm 包 `@ebony-vinyl/dsh-our-free-model` 安装**
- 同一个 profile 只能保留一种安装方式。先执行：
  `dsh plugin --profile desktop remove @ebony-vinyl/dsh-our-free-model`，再运行本脚本。

**7. 安装完成但设置页 / 模型选择器没有变化**
- 必须**完全退出**应用（托盘 → 退出）再启动；只刷新页面或只关窗口不够。
- 确认安装的是当前使用的 profile（脚本会打印目标 profile）。

**8. 双击后窗口一闪而过 / 中文乱码**
- 请直接以「右键 → 使用 PowerShell 运行」或按上文命令行方式运行；
  `.cmd` 已执行 `chcp 65001`，但个别终端字体/代码页仍可能显示异常，不影响安装结果。
- 运行日志在 `%TEMP%\our-free-model-install-<时间>.log`。

**9. 杀毒软件/系统提示 `DeepSeek Harness.exe` 或 `pnpm` 操作**
- 桌面端自带的 `dsh` CLI 就是以 `DeepSeek Harness.exe` 的 Node 模式运行的，
  由脚本调用时可能触发提示，选择允许即可。

**10. 想恢复干净状态**
- 双击卸载脚本；再手动删除 `%USERPROFILE%\.dsh\our-free-model`（数据）与 profile 下
  `vendor\` 中的插件包。

---

## 安全与合规

- 脚本只从**官方 GitHub Release** 获取安装包，并强制用官方 `SHA256SUMS` 校验；
  使用 `-SkipChecksum` 会失去这层保护。
- 本脚本与 DeepSeek、插件作者均无隶属关系；它只是把官方安装流程自动化。
- 请勿安装 npm 上那个裸名的 `dsh-our-free-model`（不是插件官方发布）；也不要与
  `@ebony-vinyl/dsh-our-free-model` 混装。
- 插件是第三方项目；免费模型额度由上游提供，随时可能变化；
  **Kilo 免费池明确声明 prompt 可能被上游记录**，请勿通过免费车道发送密码、密钥、
  隐私或商业机密。
- 脚本不会上传任何本机数据；它只访问 GitHub（下载插件包与校验文件）。

---

## 实测记录

以下为本仓库发布前的实测环境与结果（2026-11-22）：

- 环境：Windows 10 Pro 25H2（build 26200）、Windows PowerShell 5.1、
  DeepSeek Harness 桌面端 `0.2.2-rc.5`、目标插件版本 `2.8.9`。
- 本机桌面端安装在 `D:\DeepSeek Harness`（非默认盘，验证了注册表/进程探测）。

| 用例 | 结果 |
| --- | --- |
| 真实环境 `-DryRun`：探测数据目录、`desktop` profile、内置 `dsh` CLI、当前已安装版本 | ✅ |
| 干净 `DSH_HOME`（路径**含空格**）从本地 tarball 安装：校验 → 安装 → 安装后检查 | ✅ |
| `dsh --profile <p> --dump-config` 中出现 `- id: our-free-model`（确认可被 DSH 加载） | ✅ |
| 无缓存时完整下载官方 30 MB 插件包并通过 SHA-256 校验后安装 | ✅ |
| 同版本重复运行自动跳过（幂等） | ✅ |
| `-Force` 在真实 `desktop` profile 上重装 | ✅ |
| 卸载、重复卸载（幂等） | ✅ |
| 双击 `.cmd` 包装器：参数透传、`chcp`、结束暂停、退出码 | ✅ |
| 错误路径：无效 `-AppDir`、缺失 `-Tarball`、错误版本号、被篡改的插件包（SHA-256 拒绝）、与 npm scoped 包混装 | ✅ 均退出码 1 并给出中文指引 |

> 未在「从未启动过桌面端」的全新系统上做整机验收；脚本对该情况会给出明确提示。
> 浏览器内的界面渲染与模型可用性取决于上游服务，不在本脚本验证范围内。

---

## 目录结构

```text
dsh-our-free-model-script/
├─ 一键安装 Our Free Model.cmd    # 双击安装 / 更新的入口
├─ 一键卸载 Our Free Model.cmd    # 双击卸载的入口
├─ install-our-free-model.ps1     # 实际执行逻辑（PowerShell 5.1，UTF-8 BOM）
├─ README.md                      # 本说明
└─ .gitattributes                 # 行尾规范（Windows 换行）
```

---

## 版本记录

### v1.0.0（2026-11-22）

- 首个版本：一键安装 / 更新 / 卸载；
- 官方 Release + SHA-256 校验；
- 自动探测桌面端与 profile；
- 支持 `-DryRun`、`-Force`、`-Version`、`-Tarball`、`-SkipChecksum`；
- 安装后完整性检查与中文故障指引。

---

## 反馈与免责

- 脚本问题 / 建议：欢迎在本仓库提 Issue。
- 插件本身的问题（模型不可用、登录、网关等）：请到
  [Ebony-Vinyl/dsh-our-free-model](https://github.com/Ebony-Vinyl/dsh-our-free-model/issues) 反馈。
- 本脚本按「现状」提供，不附带任何担保；使用第三方插件与免费模型的风险由使用者自行承担。
