# Claude 娘 · 向日葵：Codex 原生桌宠

保留橙发、向日葵发饰和橙白黑裙装，让 Claude 娘在 Codex 里陪你工作。任务失败时会双手握拳、泪流满面大哭。

![动画状态预览](preview.gif)

左右移动采用视频里立绘整体平移的方式，保留站姿与轻微呼吸、眨眼：

![站姿平移效果](movement-preview.gif)

## 安装

在仓库根目录运行：

```sh
python3 codex/install.py
```

Windows 可使用 `python codex/install.py`。安装脚本仅使用 Python 标准库，无需 Pillow。

然后打开 Codex **设置 → Mini & Pets / Pets（桌宠）**：

1. 点 **Refresh / 刷新**，让应用重新读取本地素材。
2. 选择 **Claude 娘 · 向日葵**。
3. 点页面上的 **Show mini / Show pet（显示桌宠）** 打开悬浮窗。选中角色只是在选择外观，不代表窗口已经打开。
4. 想让它一直留在桌面上，将 **Visibility** 设为 **Always visible**。

也可以在 Mac 上按 **Option+Space** 打开浮动控件，或在应用输入框使用 `/pet`。以上显示入口见 [官方桌宠说明](https://learn.chatgpt.com/docs/pets)。

也可以手动把整个 `claude-sunflower` 文件夹复制到 `~/.codex/pets/`；设置了 `CODEX_HOME` 时复制到该目录下的 `pets/`。保留包内的 `pet.json` 和 `spritesheet.webp` 两个文件。

重复运行安装脚本会识别相同版本。如果目标目录已有不同内容，脚本会停止；使用 `--replace` 可先备份旧包到 `CODEX_HOME/pet-backups/` 再更新。安装过程不修改你的其他桌宠或应用偏好。

## 没有显示时

- **列表中没有角色**：点 Refresh。当前版本会缓存自定义角色列表，只重新打开设置页不会保证重新读取文件。
- **能选中角色，却没有悬浮窗**：点 Show mini / Show pet，或按 Option+Space。不要把选中外观当作启动窗口。
- **点击其他窗口后就消失**：检查 Visibility 是否设为 On demand；常驻使用 Always visible。
- **Mini 小窗出现，但人物没显示**：检查页面上人物显示选项，并确认选的是角色而不是只有控件的 Mini。
- **内置 Codex、Dewey 等角色也全部没有图像，但卡片文字正常**：先完全退出客户端后重新打开，检查内置图像是否恢复。这属于客户端共用显示环节的排查，重新安装单个 Claude 素材包不能确定解决。

## 待机漫游

本素材包保留站姿平移。Codex 客户端控制动画状态和真实窗口位置，当前 `pet.json` 不支持随机表情计时器、移动范围或速度。需要待机随机表情、在拖放位置附近漫游、移动时轻微上下浮动时，请使用本 fork 的 [macOS 独立桌宠](../macos/README.md)，这些行为已在独立宿主中实现。

## 动画状态

这是 Codex 原生 v1 素材包，9 个状态共 57 帧。无需额外窗口、Claude 插件钩子或后台服务。

| 状态 | 动作 | 帧数 |
|---|---|---:|
| idle | 安静站立、呼吸、眨眼 | 6 |
| running-right | 站姿整体向右平移，轻微呼吸、眨眼 | 8 |
| running-left | 站姿整体向左平移，轻微呼吸、眨眼 | 8 |
| waving | 挥手 | 4 |
| jumping | 蓄力、起跳、落地 | 5 |
| failed | 握拳大哭、泪流变化 | 8 |
| waiting | 等待你回复或确认 | 6 |
| running | 专注处理任务 | 6 |
| review | 审阅与思考 | 6 |

具体触发由 Codex 决定；`running` 表示工作。左右移动保留 Codex 要求的状态名称，但画面采用视频立绘式平移：人物面向和站姿保持一致，实际位置移动由 Codex 控制。此包采用 v1 格式，没有 v2 的鼠标方向追视。

图集为透明 WebP，1536×1872，8 列×9 行，单格 192×208；各行未使用的格子全透明。状态表和帧时长见 [animation.json](animation.json)。来源与生成方式见 [SOURCES.md](SOURCES.md)。

## 原版 Claude 插件的大哭表情

`pet/sprites/crying.png` 可独立使用。整轮任务以 `reason: error` 结束时显示大哭；普通工具报错仍为惊慌，连续三次工具报错仍为石化。

Claude Windows 悬浮窗和 Codex 原生桌宠是两个独立入口；只用 Codex 时不用安装 Claude 插件。
