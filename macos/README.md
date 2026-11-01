# macOS 独立桌宠

一个原生 Swift / AppKit 应用。双击 **Claude Desktop Pet.app**，Claude 娘就会以透明背景悬浮在桌面上；无需运行 Python、网页窗口或额外服务。

![macOS 实机大哭表情](preview.png)

支持 Apple Silicon 和 Intel Mac，macOS 12 或更新版本。安装后的应用不需要开发工具或第三方运行环境。

## 使用

- **拖动角色**：像视频立绘一样整体平移，保留当前表情和细微动画，双腿保持原姿势。
- **右键角色 / 点击菜单栏太阳图标**：选择 11 种表情（原有十种，加上大哭）；调整大小、暂停动画、置顶、隐藏或退出。
- **自动跟随 Codex**：任务开始时工作，全部已观察到的任务完成后庆祝，再回到待机。手动选择表情后会保持该表情，直到重新选择自动跟随。
- **双击角色**：打开 Codex。
- 透明像素可以点击穿透，不会用整个矩形挡住桌面；拖动不抢键盘焦点。
- 位置和大小会自动保存，多显示器或显示器变化时会将角色保持在可见区域内。

9 组动画共 57 帧，另带原版立绘和新增大哭 PNG。素材来源与生成提示词见 [来源记录](../codex/SOURCES.md)。

## 从源码构建和安装

构建需要 Apple 的 Xcode Command Line Tools（`xcode-select --install`）。在仓库根目录运行：

```sh
./macos/install.sh
```

脚本会构建 Apple Silicon + Intel 通用应用，校验素材与活动监听逻辑，安装到 `~/Applications/Claude Desktop Pet.app` 并启动。单独构建使用：

```sh
./macos/build.sh
```

产物位于 `macos/build/Claude Desktop Pet.app`。`./macos/install.sh --no-open` 可只安装；`--destination DIRECTORY` 可选择应用目录。更新已安装的本应用时，请先从菜单退出；安装脚本会备份旧应用，不覆盖其他应用。

本地构建使用临时签名，没有 Apple Developer ID 公证；在本机从源码构建后运行即可。源码构建自测也可手动运行：

```sh
"macos/build/Claude Desktop Pet.app/Contents/MacOS/ClaudeDesktopPet" --self-test
```

## Codex 状态跟随的范围

监听采用只读方式，从本机 Codex 日志的新事件提取任务开始、结束与轮次标识。应用启动时跳过已有历史；重启后会等待新的任务证据。多个聊天同时工作时按活动任务集合聚合，子代理的复制历史不会重复计数。

索引和日志位于 `CODEX_HOME`，未设置时使用 `~/.codex`。只查询最近主聊天的日志路径等必要字段，不读取索引里的标题、消息预览或首条用户消息。桌宠不展示、保存或上传对话正文，也不修改 Codex 设置；无需录屏、辅助功能或 API 密钥。

这是对当前本地日志格式的兼容实现，不是 Codex 的稳定公开事件 API。日志格式或索引不可用时，桌宠仍可手动切换表情。普通命令错误、网络重试，以及没有成败字段的任务完成事件，不会被猜成整轮失败；大哭始终可从右键菜单选择，只有明确的终止失败事件才自动触发。长期没有事件时回到休息，不判定失败。

## 与其他入口的关系

这个 `.app` 独立于 [Codex 内置桌宠素材包](../codex/README.md)，可以直接在 macOS 桌面显示。原仓库的 Windows Claude 插件仍使用原有 Python 窗口。感谢 [wangmeng003 的 Mac 移植版](https://github.com/wangmeng003/claude-desk-pet-mac) 提供实现思路；本应用使用独立编写的 Swift 代码。

若原先已打开 Codex 内置桌宠，可在 Codex 设置里关闭它，以免桌面同时出现两只。
