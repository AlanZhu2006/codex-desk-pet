# 四种经典 Codex 风格动画

内置 imagegen 根据 `references/` 中的经典 Codex 图帧生成。原始表情只提供神情和手势参考；新画面保留鲜亮橙发、白色高光、头身比例、服装与清晰边缘。石化通过抱书、发白的神情和局部石纹表达，保留彩色造型。

`sources/` 保存四份原始透明 PNG，每份六帧。所有生成提示词见仓库的 `codex/prompts/unified-expressions/`；`manifest.json` 记录引用顺序、原图及提示词哈希、目标行和真实播放时长。生成使用内置工具，未使用 CLI/API 备用路径。

`build_atlas.py` 仅执行技术性人物提取、尺寸对齐和透明图集打包，不重绘、不调色。运行需要 Python 和 Pillow。可从仓库根目录重新打包：

```sh
python3 macos/artwork/unified-expressions/build_atlas.py \
  --source-dir macos/artwork/unified-expressions/sources \
  --output macos/Resources/CodexExtraExpressions.png \
  --qa-dir /tmp/claude-extra-expressions-qa
```

结果是1536×832的sRGB透明PNG，每格192×208，四行依次为眯眼笑、慌张、委屈、石化。每行前六格有效、最后两格透明。构建应用时会验证11组动画覆盖、空格透明、有效帧不同，以及原有七组像素未被改写。

这些素材是基于原角色的AI生成粉丝创作，具体来源及署名见 `codex/SOURCES.md`。
