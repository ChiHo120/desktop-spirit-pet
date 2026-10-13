# 桌面小灵宠 · Desktop Spirit Pet

一个使用 Windows PowerShell 和 WPF 编写的桌面小灵宠。透明、无边框的悬浮窗口配合动画，展示电脑实时硬件与网络状态，无需额外安装运行时。

## 功能

- 显示 CPU 使用率、频率、内存、GPU 使用率以及可读取的热区温度。
- 展示磁盘总用量，点击后展开各盘信息，同时显示磁盘读写活动。
- 显示网络速度、Wi-Fi 地址，以及识别到的 VPN 公网和隧道地址。
- 显示电池、开机时长和设备信息。
- 支持拖动、收起、置顶、托盘找回和可选的开机启动。
- 支持滚轮、滑条和右键菜单缩放，范围为 10%–140%。

## 启动

适用于 Windows 桌面环境，使用系统自带的 Windows PowerShell 5.1 与 WPF。已在 Windows 11 上运行；不同设备的传感器可用性可能不同。

1. 下载仓库并解压，或克隆到本地。
2. 双击 `start.bat`。
3. 拖动小灵宠调整位置，单击收起或展开，右键打开菜单。

也可以在项目目录运行：

```powershell
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File .\pet.ps1
```

启动命令中的 `ExecutionPolicy Bypass` 仅作用于该 PowerShell 进程，不修改系统持久执行策略。脚本使用 UTF-8 BOM 编码，修改时请保留编码以兼容 Windows PowerShell。

## 设置与网络请求

窗口位置、置顶、展开和缩放设置保存在 `%LOCALAPPDATA%\桌面小灵宠\window.json`，运行日志也保存在该目录。右键菜单中可启用或关闭开机启动。

检测到 VPN 后，公网 IP 与位置查询会请求 `ip-api.com`（HTTP），失败时尝试 `ipwho.is`（HTTPS）。这些服务能够看到发起请求的公网 IP；位置结果是 IP 地理信息，可能与实际位置不同。内网隧道地址在本机读取并显示，不作为查询参数发送给上述服务。

温度取决于固件暴露的 ACPI 热区，不一定等同于 CPU 核心温度；GPU、网络和其他性能计数器也可能因设备、驱动或系统环境而不可用。

## 文件

| 文件 | 用途 |
| --- | --- |
| `pet.ps1` | WPF 窗口、动画、交互与后台采样 |
| `sensors.ps1` | 性能计数器、硬件、电池及网络信息读取 |
| `start.bat` | 双击启动入口 |
| `check-place.ps1` | IP 位置标签的示例检查 |

本机专属快捷方式、项目记忆和运行输出不包含在仓库内。

## 检查

读取硬件快照（输出可能包含本机和网络信息，请勿直接公开）：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\pet.ps1 -SelfTest
```

检查位置标签：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\check-place.ps1
```
