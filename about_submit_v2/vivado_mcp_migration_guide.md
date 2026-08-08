# Vivado MCP 迁移到本地电脑完整指南

> 适用场景：从云桌面（已有 Vivado MCP）迁移配置到本地 VS Code
> 日期：2026-08-08

---

## 一、云桌面现有配置全貌

### 1.1 MCP 服务器

MCP 由一个 VS Code 扩展提供：

```
扩展 ID:    amd.vivado-ai-extension
版本:       0.6.8
安装路径:   /tool/vscode-extensions/amd.vivado-ai-extension-0.6.8/
二进制:     bin/vivado-mcp-server-linux-amd64-0.6.8
```

### 1.2 VS Code 配置文件

云桌面上涉及三个配置文件：

#### (a) `~/.config/Code/User/mcp.json`（当前使用 HTTP 模式）

```json
{
  "servers": {
    "vivado-mcp-server": {
      "type": "http",
      "url": "http://127.0.0.1:18090/mcp"
    }
  }
}
```

#### (b) `~/.codebuddy/mcp.json`（备用 stdio 模式）

```json
{
  "mcpServers": {
    "vivado-mcp": {
      "command": "/tool/vscode-extensions/amd.vivado-ai-extension-0.6.8/bin/vivado-mcp-server-linux-amd64-0.6.8",
      "args": ["--stdio-bridge"],
      "type": "stdio",
      "env": {
        "VIVADO_PATH": "/tool/2025.2/Vivado/bin/vivado"
      }
    }
  }
}
```

#### (c) 项目 `.vscode/settings.json`

```json
{
  "chat.mcp.autostart": "always"
}
```

### 1.3 运行时环境

```
HTTP 端口:  18090
Vivado:     /tool/2025.2/Vivado/bin/vivado
日志:       ~/.vivado-ai/server_<hostname>.log
```

---

## 二、两种运行模式对比

| 特性 | HTTP 模式 | stdio 模式 |
|---|---|---|
| 启动方式 | 手动启动服务器进程，VS Code 通过 HTTP 连接 | VS Code 自动 spawn 子进程 |
| 配置复杂度 | 需要先启动 MCP 服务器 | 一键配置，自动管理 |
| 调试便利性 | 可以独立查看服务器日志 | 日志混在 VS Code 输出中 |
| 适用场景 | 远程服务器、调试 | **推荐用于本地开发** |
| 服务器进程 | `vivado-mcp-server` 独立运行在后台 | VS Code 管理生命周期 |

**推荐本地电脑使用 stdio 模式**：配置最简单，不需要手动管理进程。

---

## 三、本地迁移步骤（stdio 模式，推荐）

### 步骤 1：获取 MCP 扩展文件

#### 方法 A：从 VS Code 扩展商店安装（需联网）

在本地 VS Code 中：
1. 打开 `Extensions` 面板（Ctrl+Shift+X）
2. 搜索 `amd.vivado-ai-extension`
3. 安装版本 ≥ 0.6.8

#### 方法 B：从云桌面复制（离线环境）

在云桌面终端执行，找到扩展目录并打包：

```bash
# 查找扩展安装位置
ls /tool/vscode-extensions/amd.vivado-ai-extension-*

# 打包整个扩展目录
tar czf /tmp/vivado-ai-extension.tar.gz \
  -C /tool/vscode-extensions \
  amd.vivado-ai-extension-0.6.8/

# 上传到临时文件服务（在本地浏览器下载）
curl --upload-file /tmp/vivado-ai-extension.tar.gz https://transfer.sh/
```

下载后解压到你本地的 VS Code extensions 目录：
- **Windows**: `%USERPROFILE%\.vscode\extensions\amd.vivado-ai-extension-0.6.8\`
- **Linux**: `~/.vscode/extensions/amd.vivado-ai-extension-0.6.8/`
- **macOS**: `~/.vscode/extensions/amd.vivado-ai-extension-0.6.8/`

### 步骤 2：确认本地 Vivado 安装路径

在本地终端确认 Vivado 可执行文件位置：

**Windows**（通常）：
```
C:\Xilinx\Vivado\2025.2\bin\vivado.bat
```

**Linux**（通常）：
```
/tools/Xilinx/Vivado/2025.2/bin/vivado
```

验证：
```bash
# Linux
/path/to/vivado -version

# Windows (PowerShell)
& "C:\Xilinx\Vivado\2025.2\bin\vivado.bat" -version
```

### 步骤 3：创建 mcp.json 配置

在你的**本地电脑**上，找到 VS Code 用户配置目录：

| 操作系统 | 路径 |
|---|---|
| Windows | `%APPDATA%\Code\User\` |
| Linux | `~/.config/Code/User/` |
| macOS | `~/Library/Application Support/Code/User/` |

在该目录下创建或编辑 `mcp.json`：

**Windows 示例**：
```json
{
  "mcpServers": {
    "vivado-mcp": {
      "command": "%USERPROFILE%\\.vscode\\extensions\\amd.vivado-ai-extension-0.6.8\\bin\\vivado-mcp-server-windows-amd64-0.6.8.exe",
      "args": ["--stdio-bridge"],
      "type": "stdio",
      "env": {
        "VIVADO_PATH": "C:\\Xilinx\\Vivado\\2025.2\\bin\\vivado.bat"
      }
    }
  }
}
```

**Linux 示例**：
```json
{
  "mcpServers": {
    "vivado-mcp": {
      "command": "~/.vscode/extensions/amd.vivado-ai-extension-0.6.8/bin/vivado-mcp-server-linux-amd64-0.6.8",
      "args": ["--stdio-bridge"],
      "type": "stdio",
      "env": {
        "VIVADO_PATH": "/tools/Xilinx/Vivado/2025.2/bin/vivado"
      }
    }
  }
}
```

> **重要**：用绝对路径，不要用 `~` 或 `%USERPROFILE%` 等 shell 展开符号。

### 步骤 4：项目 settings.json

在项目根目录的 `.vscode/settings.json` 中添加：

```json
{
  "chat.mcp.autostart": "always"
}
```

如果你的项目还没有 `.vscode` 目录，创建它：
```bash
mkdir -p .vscode
```

### 步骤 5：重启 VS Code 并验证

1. 完全关闭 VS Code（不是 reload window）
2. 重新打开项目
3. 等待 MCP 初始化（首次启动可能需要几十秒，因为会启动 Vivado 进程）

**验证方法 A**：在 VS Code Chat 中发送：
```
list available MCP tools
```
或直接输入 Vivado TCL 命令如 `get_parts`。

**验证方法 B**：查看 VS Code 输出面板（Output → 选择 "MCP" 或 "Vivado AI"），确认无报错。

### 步骤 6：验证 Vivado 功能

在 Chat 中测试：
```
打开 Vivado 项目 ./project/thinpad_top.xpr，报告当前使用的器件型号
```

如果 MCP 正常工作，它会调用 `vivado_execute` 执行 `get_property PART [current_project]` 并返回 `xc7a200tfbg676-2`。

---

## 四、本地迁移步骤（HTTP 模式，调试用）

如果你更喜欢 HTTP 模式（方便调试，可独立查看服务器日志）：

### 4.1 后台启动 MCP 服务器

**Windows（PowerShell）**：
```powershell
$env:VIVADO_PATH = "C:\Xilinx\Vivado\2025.2\bin\vivado.bat"
Start-Process -NoNewWindow `
  "$env:USERPROFILE\.vscode\extensions\amd.vivado-ai-extension-0.6.8\bin\vivado-mcp-server-windows-amd64-0.6.8.exe"
```

**Linux**：
```bash
VIVADO_PATH=/tools/Xilinx/Vivado/2025.2/bin/vivado \
  ~/.vscode/extensions/amd.vivado-ai-extension-0.6.8/bin/vivado-mcp-server-linux-amd64-0.6.8 &
```

服务器默认监听 `http://127.0.0.1:18090/mcp`。

### 4.2 mcp.json 配置

```json
{
  "servers": {
    "vivado-mcp-server": {
      "type": "http",
      "url": "http://127.0.0.1:18090/mcp"
    }
  }
}
```

### 4.3 关闭服务器

```bash
# Linux
pkill vivado-mcp-server

# Windows
Get-Process vivado-mcp-server | Stop-Process
```

---

## 五、不同平台的 MCP 二进制文件名

| 平台 | 二进制文件名 |
|---|---|
| Linux x86_64 | `vivado-mcp-server-linux-amd64-0.6.8` |
| Windows x86_64 | `vivado-mcp-server-windows-amd64-0.6.8.exe` |

> 如果扩展版本不同，文件名中的版本号会有变化。可以在扩展的 `bin/` 目录下确认实际文件名。

---

## 六、常见问题排查

### Q1：MCP 连接失败 / 工具不显示

1. 确认 `mcp.json` 中 `command` 路径**绝对正确**，指向真实存在的二进制
2. 确认 `VIVADO_PATH` 指向的 `vivado` / `vivado.bat` 存在且可执行
3. 确认 Vivado License 有效
4. 查看 VS Code 输出面板（Output → MCP 或 Vivado AI）

### Q2：Vivado 启动慢 / MCP 超时

Vivado 首次初始化可能需要 30-60 秒。如果超时：
- 增加 VS Code 的 MCP 超时设置（在 `mcp.json` 中加 `"timeout": 120000`）
- 确保 Vivado 没有弹出 GUI 对话框（License 过期等）

### Q3：路径中有空格（Windows 常见）

```json
// 错误：路径有空格但没有引号转义
"command": "C:\\Program Files\\...\\vivado-mcp-server.exe"

// 正确：JSON 中反斜杠需要双重转义
"command": "C:\\Xilinx\\Vivado\\2025.2\\bin\\vivado.bat"
```

建议不要安装 Vivado 到有空格的路径（如 `Program Files`）。

### Q4：macOS 支持吗？

目前 MCP 扩展包中只看到 Linux 和 Windows 的二进制。如果需要在 macOS 上使用，可能需要联系 AMD 获取 Darwin 版本。

### Q5：我可以同时用 MCP 和手动打开 Vivado GUI 吗？

可以。MCP 启动的是 TCL 模式的 Vivado（`gui_mode=false`），与手动打开的 GUI 是独立的进程。但注意 License 可能限制同时运行的实例数。

---

## 七、云桌面 skills 目录说明

项目中的 skills 是本地 Markdown 文件，**不需要迁移**。它们位于：

```
/home/hgd011/Downloads/submit_v2/.claude/skills/
/home/hgd011/.claude/skills/
```

这些 skills 是 AI 助手的提示词模板，只在当前会话环境中生效，本地不需要复制。

---

## 八、速查清单

迁移完成后，验证以下项目：

- [ ] VS Code 扩展 `amd.vivado-ai-extension` 已安装（版本 ≥ 0.6.8）
- [ ] `mcp.json` 中 `command` 路径指向正确的 MCP 二进制
- [ ] `mcp.json` 中 `VIVADO_PATH` 指向正确的 Vivado 可执行文件
- [ ] 项目 `.vscode/settings.json` 包含 `"chat.mcp.autostart": "always"`
- [ ] Vivado License 有效
- [ ] 重启 VS Code 后 MCP 工具可用
- [ ] 能在 Chat 中执行 Vivado TCL 命令
