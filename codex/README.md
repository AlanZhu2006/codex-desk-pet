# Claude 娘 · 向日葵：Codex 原生桌宠

保留橙发、向日葵发饰和橙白黑裙装，让 Claude 娘在 Codex 里陪你工作。任务失败时会双手握拳、泪流满面大哭。

![动画状态预览](preview.gif)

## 安装

在仓库根目录运行：

```sh
python3 codex/install.py
```

Windows 可使用 `python codex/install.py`。安装脚本仅使用 Python 标准库，无需 Pillow。

然后打开 Codex **设置 → Mini & Pets / Pets（桌宠）**，刷新本地桌宠，选择 **Claude 娘 · 向日葵**。如果当前版本没有刷新按钮，可重新打开设置或重启应用。

也可以手动把整个 `claude-sunflower` 文件夹复制到 `~/.codex/pets/`；设置了 `CODEX_HOME` 时复制到该目录下的 `pets/`。保留包内的 `pet.json` 和 `spritesheet.webp` 两个文件。

重复运行安装脚本会识别相同版本。如果目标目录已有不同内容，脚本会停止；使用 `--replace` 可先备份旧包到 `CODEX_HOME/pet-backups/` 再更新。安装过程不修改你的其他桌宠或应用偏好。

## 动画状态

这是 Codex 原生 v1 素材包，9 个状态共 57 帧。无需额外窗口、Claude 插件钩子或后台服务。

| 状态 | 动作 | 帧数 |
|---|---|---:|
| idle | 安静站立、呼吸、眨眼 | 6 |
| running-right | 向右移动 | 8 |
| running-left | 向左移动 | 8 |
| waving | 挥手 | 4 |
| jumping | 蓄力、起跳、落地 | 5 |
| failed | 握拳大哭、泪流变化 | 8 |
| waiting | 等待你回复或确认 | 6 |
| running | 专注处理任务 | 6 |
| review | 审阅与思考 | 6 |

具体触发由 Codex 决定；`running` 表示工作，左右移动由单独两行动画负责。此包采用 v1 格式，没有 v2 的鼠标方向追视。

图集为透明 WebP，1536×1872，8 列×9 行，单格 192×208；各行未使用的格子全透明。状态表和帧时长见 [animation.json](animation.json)。来源与生成方式见 [SOURCES.md](SOURCES.md)。

## 原版 Claude 插件的大哭表情

`pet/sprites/crying.png` 可独立使用。整轮任务以 `reason: error` 结束时显示大哭；普通工具报错仍为惊慌，连续三次工具报错仍为石化。

Claude Windows 悬浮窗和 Codex 原生桌宠是两个独立入口；只用 Codex 时不用安装 Claude 插件。
