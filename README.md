# PCL 下载功能恢复工具

把 PCL 的「下载 → 原版游戏」板块找回来。

**不改二进制、不打补丁、不注入**。做法是：把启动器换成最后一个仍内置原版下载的**官方正式版 2.14.0.0**，并关掉自动更新。

---

## 快速开始

双击 `PCL-Download-Restore.bat` 即可。它会自动找到 PCL 目录。

```bat
:: 指定目录
PCL-Download-Restore.bat -PclDir "D:\PCL2"

:: GitHub 连不上时（任何镜像都安全，见下文哈希校验）
PCL-Download-Restore.bat -Proxy "https://hk.gh-proxy.com/"

:: 撤销，回到你原来的版本
PCL-Download-Restore.bat -Restore
```

也可以用 PowerShell 直接跑源码：

```powershell
.\Restore-PCLDownload.ps1 -PclDir "D:\PCL2"
```

要求：Windows 10/11 自带的 Windows PowerShell 5.1，无需安装任何依赖。

---

## 实现原理

### 1. 问题不是「开关被关」，是「整块被删」

PCL 2.99.0.0 的更新日志写得很明确：

> 删除：为遵守相关法律法规，PCL 暂时不再提供 MC 下载功能，非常抱歉 qwq……

排查过程中先后有两个误解被排除：

- **不是远端配置开关**。`minecraft/download.json` 返回 `[]` 看起来很像总闸，但翻源码可知它只是 `Versions.Merge(...)` 用的「额外版本列表」，空数组是正常状态。改它没有意义。
- **不是某个可勾选的设置**。真正相关的是 `ModSecret.vb` 里的编译期常量：

  ```vb
  Public Const RestrictMcDownload As Boolean = True
  ```

  常量会被内联进调用点，二进制里连字符串都找不到（实测 2.13.0.1 / 2.13.1.1 / 2.99.0.0 三个 exe 中 `RestrictMcDownload` 命中数为 0）。

既然逻辑是编译进去的，改配置、清缓存、换下载源都不会有作用。

### 2. 为什么不做二进制补丁

两条路都验证过，都不可行：

- **「把下载板块移植过去」**：下载页与 `ModDownload`、`Settings`、`FrmMain.PageSubType`、XAML 资源深度耦合。跨版本搬一个页面类，等于把整个程序集的关系重新链接一遍，做不成可维护、可分发的脚本。
- **「给 2.99 打 IL 补丁」**：需要先定位每个内联的 `ldc.i4.1` 调用点，成本高；更致命的是 **PCL 会自动更新**，补丁在一次更新后即失效——这一点在调试时被现场复现过：启动器在一次自动更新中把 2.13.1.1 直接换成了 2.99.0.0。

所以唯一稳定的做法是**不修改任何字节**，直接使用官方发布的、功能完好的旧构建。

### 3. 怎么确定哪个版本还带下载

不用猜。在 exe 里按 UTF-16LE 搜拦截文案即可：

```powershell
$u = [Text.Encoding]::Unicode.GetString([IO.File]::ReadAllBytes($exe))
$u.Contains('不再提供 MC 下载功能')   # True = 该版本已移除
```

实测结果：

| 版本 | 发布日期 | 含拦截文案 | 原版下载 |
|---|---|---|---|
| 2.13.0.1 | 2026-07-03 | 否 | ✅ |
| 2.13.1.1 | 2026-08-06 | 否 | ✅ |
| **2.14.0.0** | 2026-10-16 | 否 | ✅ |
| 2.99.0.0 | 2026-10-20 | **是** | ❌ |

选 **2.14.0.0**：它是移除前的最后一个正式版，只比 2.99 早几天，功能上几乎不吃亏。

### 4. 为什么能从「官方渠道」拿到旧版

PCL 的仓库里有一个随版本提交的 `最新正式版.zip`，每次发版都会更新。它的 **git 历史**因此保存了每个版本的完整官方包：

```
https://raw.githubusercontent.com/Meloong-Git/PCL/<commit>/最新正式版.zip
```

2.14.0.0 对应 commit `5ef81e490a`。包里只有一个文件——`Plain Craft Launcher 2.exe`，没有别的东西需要处理。

### 5. 三道哈希校验（这是能开源分发的前提）

脚本不含任何二进制，每次现场下载，然后：

| 校验 | 期望值 |
|---|---|
| 压缩包 SHA-256 | `0835D346CD0F95C1472A3C0655D66E6CA8B7E4494CA0083768E3316F2CD4E7B1` |
| exe SHA-256 | `5582952DED3B443503F66C23B810802BD20F1A3E847B54D9E09653A825859A36` |
| exe MD5 | `B0756EE600D34B93DC841E0F2CA00096` |

再加字节数与文件版本号双重比对。

其中 MD5 还能**交叉验证来源**：官方仓库里存在

```
patches/Release 2.14.0.0 b0756ee600d34b93dc841e0f2ca00096.patch
```

补丁文件名由「构建类型 + 版本 + 源 exe 的 MD5」拼成。我们的 MD5 与它逐字吻合，说明拿到的就是官方更新器认可的那份构建。

**因此脚本可以放心支持第三方加速前缀**——镜像被投毒也过不了哈希校验。
#### 下载源与实测顺序

**2026-10-24 重新实测**（大陆网络、直连、不走任何加速工具）：

| 源 | 结果 |
|---|---|
| `raw.githubusercontent.com` | ❌ 20 秒超时 |
| `github.com/.../raw/...` | ❌ 302 跳转到 `raw.githubusercontent.com`，一并失效 |
| `jsdelivr.b-cdn.net` | ✅ 5.0 s |
| `cdn.jsdmirror.com` | ✅ 6.0 s |
| `gcore.jsdelivr.net` | ✅ 15.7 s |

也就是说，**原来的前两个源在大陆基本必然失败**（早期测得的 0.2 s 是命中了本机加速工具的本地代理，不代表直连可用）。

因此从 v1.0.1 起，尝试顺序改为：

1. `jsdelivr.b-cdn.net`（国内可达，最快）
2. `cdn.jsdmirror.com`
3. `gcore.jsdelivr.net`
4. `hk.gh-proxy.com`
5. **fork 兜底**：`QingDongmen/PCLbk`、`jinfanhao1/PCL` —— fork 保留同一 commit 对象，上游被删/被封也能取到同一份文件
6. `github.com/.../raw/...` 与 `raw.githubusercontent.com`（能翻墙的用户）

所有源下载后都过 SHA-256 校验，镜像投毒过不了；fork 与上游逐字节相同。若全部失败，可用 `-Proxy` 追加自定义加速前缀。

### 6. 替换流程

1. 定位 PCL 目录（参数 → 正在运行的进程 → 脚本目录/当前目录）。
2. 关闭 PCL（先请求退出，超时才强制结束）。
3. 备份现有 exe 为 `Plain Craft Launcher 2.exe.bak-<原版本>`。
4. 写入新 exe。
5. 在 `PCL\Setup.ini` 写入 `SystemSystemUpdate:3`。

### 7. `SystemSystemUpdate:3` 是什么

`SystemSystemUpdate` 是 PCL 自己读取的设置键（在 2.13.0.1 与 2.99.0.0 的字符串表中均存在），写在 `PCL\Setup.ini` 里，值为 `3` 表示不自动更新。

不写它的后果很直接：下次启动会被自动升回 2.99，下载板块再次消失。

---

## 数据安全边界

脚本**只会修改两个文件**：

```
<PCL目录>\Plain Craft Launcher 2.exe
<PCL目录>\PCL\Setup.ini          （仅追加一行）
```

以下内容**只读不写**：

| 数据 | 位置 | 说明 |
|---|---|---|
| 已安装的 MC 版本 | `.minecraft\versions\` | 含各自的 `mods\`、存档、配置 |
| 模组 / 整合包 / 资源包 / 光影 | `.minecraft\` 下 | 全部保持原样 |
| 账号与登录信息 | 注册表 `HKCU\Software\PCL` | 换 exe 不涉及注册表 |
| 启动器设置 | `PCL\Setup.ini` 其他行 | 只追加，不重写 |

运行结束会打印一份数据核对摘要（版本数、模组数、账号状态），可与运行前对照。

> 实测：从 2.99.0.0 降到 2.14.0.0 后，离线账号 `MODcaibaozi` 与版本 `Fresh & Smooth` 均正常显示，模组数量不变。

---

## 项目结构

```
.
├── Restore-PCLDownload.ps1      # 主逻辑（可读源码）
├── build.ps1                    # 把 .ps1 打包成单文件 .bat
├── dist/
│   └── PCL-Download-Restore.bat # 发布用成品，自带 PowerShell 负载
├── README.md
└── LICENSE
```

`.bat` 的原理：头部是纯 ASCII 的批处理，负责把自身内嵌的 PowerShell 负载释放到临时目录（UTF-8 带 BOM）再执行，退出即删除。批处理部分刻意不含任何非 ASCII 字符——否则 cmd 按 ANSI 读取会破坏控制流。

---

## 常见问题

**Q：会不会又被自动更新？**
不会。`SystemSystemUpdate:3` 已写入。想恢复更新，删掉这一行即可。

**Q：模组还能下吗？**
能。2.99 移除的只有「原版游戏」，Mod / 整合包 / 资源包 / 光影一直正常。本工具只影响原版游戏这一项。

**Q：会丢档吗？**
不会。`.minecraft` 全程不被写入。

**Q：为什么不用现成的旧版 exe？**
因为无法自证来源。网上流传的「修改版 PCL」风险很高。本工具从官方仓库取，任何人都能复核哈希。

**Q：`-Restore` 恢复的是什么？**
最近一次备份的 exe。多次来回会留下多个 `.bak-*`，可手动清理。

**Q：以后 2.14 也被下架了怎么办？**
换 pin 即可：改 `Restore-PCLDownload.ps1` 顶部的 `$Pin`（版本、commit、三个哈希），并用第 3 节的方法确认目标版本仍带下载。

---

## 免责声明

本项目仅对本地已安装软件做版本回退，不修改任何二进制内容，不绕过任何技术保护措施。是否使用由你自行判断并承担相应风险。

PCL 是 [Meloong-Git/PCL](https://github.com/Meloong-Git/PCL) 的作品，请遵守其许可协议。

## 许可

MIT
