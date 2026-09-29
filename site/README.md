# Parrotlet 官网

单页静态站,无构建步骤。视觉风格参考 Frame.io 设计系统(午夜影院:近黑画布 + 单一蓝色聚光 + 宇宙渐变)。

## 本地预览

```bash
cd site && python3 -m http.server 8765
# 打开 http://localhost:8765
```

## 部署

纯静态文件,整个 `site/` 目录丢到任何静态托管即可(GitHub Pages 直接把发布源指向本目录)。

## 内容来源

- `assets/hero-loop.webm` / `assets/hero-loop.mp4`:Hero 循环视频(15.0s,760×960 @60fps;WebM ~1.9MB，MP4 ~1.5MB)。
  页面优先加载带 alpha 的 WebM，窗口直接浮在 hero 的渐变+极光背景上，没有矩形接缝；
  MP4 是不透明兜底，浏览器不支持 WebM/alpha 时仍能正常播放。WebM 文件里 `TAG:alpha_mode=1`，
  poster 也是带 alpha 的 PNG。透明底视频的 RGB 仍保留同色系设计色，避免 alpha 被忽略时露黑底。
  **这条不是纯实拍**:输入框的聚焦放大/光晕/投影/让位是后期合成的(产品里还没有这个交互),
  所以页面上的措辞是「演示」而不是「实机演示」——别改回去。
  拍摄与合成管线见 `tools/shoot/README.md`;原始 take 在 `assets/video/takes/take5.mov`(gitignore)。
- `assets/chat-*.png`、`wordbook.png`、`settings.png`:实机截图(深色模式),对话内容由 DeepSeek 以产品真实 system prompt 生成,演示数据截图后已还原。
- `assets/hero-poster.png`:Hero 视频的 poster,从视频起始帧同管线裁出(保证与首帧构图一致)。
- `assets/appicon.png`:应用图标(`assets/icon/AppIcon.iconset/icon_512x512.png` 的拷贝)。

## 待办

- 仓库目前 private,GitHub 外链对访客 404;仓库公开后即生效。
- 有公证发行版后,把「从源码构建」CTA 换成下载按钮。
