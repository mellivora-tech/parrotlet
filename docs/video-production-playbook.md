# LanguageAgent 演示视频生产手册

> **Status:** Current · 2026-09-21  
> **适用资产：** 官网 Hero 15 秒演示片、后续同类实机演示片  
> **当前结论：** 官网优先使用 **VP9/WebM alpha 视频**，窗口直接浮在页面背景上；不透明 MP4 只作兜底。

这份文档固化这次从实机录制到官网发布的完整生产经验。`tools/shoot/README.md` 保留按时间顺序的试错记录；本文是**可执行手册**。

---

## 1. 当前产物与资产位置

| 资产 | 用途 | 当前参数 |
| --- | --- | --- |
| `site/assets/hero-loop.webm` | 官网首选视频 | VP9 alpha，760×960，60fps，15.00s，约 1.9MB；`TAG:alpha_mode=1` |
| `site/assets/hero-loop.mp4` | 浏览器兼容兜底 | H.264，不透明，760×960，60fps，15.00s |
| `site/assets/hero-poster.png` | 首帧 poster | RGBA，带 alpha，760×960 |
| `assets/video/language-agent-input-grow-wallpaper.mp4` | 不透明设计底母版 | 1140×1440，60fps，15.00s |
| `assets/video/input-grow-*.png` | 关键效果验收图 | 回弹 / 光晕 / 投影 / 两行状态 / 时间轴 |
| `assets/video/takes/take5.mov` | 当前原始 take | 已 gitignore；只作管线输入，不入库 |
| `tools/shoot/input_grow_build.sh` | 一级合成 | 放大、光晕、投影、让位、历史压暗；支持 `solid|alpha` |
| `tools/shoot/retime_build.sh` | 二级重定时 | 10 段变速、片尾微动、淡入淡出；支持 `solid|alpha` |
| `tools/shoot/seed_demo_session.py` | 演示数据准备/还原 | 先备份真实数据，写演示 session，支持 sha256 校验 |

**口径必须诚实：** 当前 15 秒片不是纯实拍。输入框聚焦放大、外溢光晕、投影、历史压暗、让位、重定时都是后期合成；产品里还没有“输入框聚焦变大”这个交互。因此官网文案用「演示」，不要写成「实机演示」。

---

## 2. 不可妥协的生产原则

1. **真实数据先备份，拍完必须还原并校验。**  
   只允许脚本动 `config.json` / `chat-sessions.json` / `words.json`；不要手改真实数据。完成后逐文件 sha256 比对。

2. **固定几何，不靠肉眼。**  
   窗口位置、录制区域、卡片裁切框、overlay 坐标全部写成常量；每次重拍后重新用像素探针确认。

3. **每个断言都要有验证。**  
   时长 / 帧数用 `ffprobe`；alpha 用 `alpha_mode` + `sips -g hasAlpha`；页面接缝用截图 + 相邻像素跳变检测；数据还原用 sha256。

4. **环境必须可恢复。**  
   临时换壁纸、隐藏窗口、改 app 数据、拖窗口位置，全部要在结束时恢复；恢复后截图或 checksum 留证。

5. **产品没有的行为不能暗示成真实行为。**  
   合成效果可以演示产品方向，但页面、README、发布文案必须明确它不是当前 app 原生交互。

---

## 3. 拍摄前置

### 3.1 编译工具

```bash
cd tools/shoot
swiftc -O click.swift -o click       # ./click <x> <y>
swiftc -O move.swift -o mmove        # ./mmove <x> <y>
swiftc -O type.swift -o typer        # ./typer <文本> <每字符秒>
swiftc -O drag.swift -o drag         # ./drag <x1> <y1> <x2> <y2> [steps]
swiftc -O key.swift -o key           # ./key <keycode> [cmd] [shift]
```

`key` 常用键码：`36=Return`、`51=Delete`、`0=A`。

### 3.2 演示数据

```bash
cd /Users/sgx/workspace/code/english-agent
python3 tools/shoot/seed_demo_session.py seed --appearance light --backup /tmp/la-shoot-backup
make app
open build/LanguageAgent.app
```

`seed_demo_session.py` 的两个关键点：

- `summary.summarizedTurns` 必须等于当前轮数；否则回复落地后 app 会触发后台总结，标题当场改名，成片里读作闪一下。
- 脚本只替换上述三个数据文件，**不碰 `app.jsonl`**。

### 3.3 窗口位置与录制区域

当前机器 / 当前窗口尺寸的固定值：

| 项 | 值 |
| --- | --- |
| 窗口尺寸 | 440×680pt |
| 窗口左上角 | `(3900,300)` |
| 录制区域 | `screencapture -v -R3870,280,570,720` |
| 录制输出 | 1140×1440 @120fps |
| 窗口在画面中的位置 | `(60,40)` |
| 画面边距 | 左 60 / 右 200 / 上 40 / 下 40 |

窗口每次重启可能回到主屏；用 `drag` 拖到 Retina 屏：

```bash
PID=$(pgrep -x LanguageAgent)
swift tools/shoot/winbounds.swift "$PID"
# 起点取标题栏中部；目标 x >= 3440 即落到 Retina 副屏
tools/shoot/drag <起x> <起y> 4120 322 90
swift tools/shoot/winbounds.swift "$PID"
```

右边距必须留足：两行输入卡放大后向右溢出约 65px（现参数 1.07x；旧 1.2x 时为 146px），因此不能只按窗口宽度取画面。

---

## 4. 实机录制

### 4.1 录前检查

- 隐藏或移开录制区域内的其它窗口。
- 桌面可换干净壁纸；最终 alpha 版会丢弃录制里的桌面像素，但干净背景便于排查和不透明兜底。
- 确认窗口标题没有因后台总结被改名。
- 确认鼠标不会停在窗口内；`screencapture -v` 会把真实光标拍进去。

### 4.2 驱动输入并录制

当前 take 的驱动节奏（窗口左上角为 `WX,WY`）：

```bash
PID=$(pgrep -x LanguageAgent)
B=$(swift tools/shoot/winbounds.swift "$PID")
WX=$(echo "$B" | awk '{print $2}' | cut -d= -f2)
WY=$(echo "$B" | awk '{print $3}' | cut -d= -f2)

# 连点两次输入框，避免 panel 第一次只激活不聚焦
tools/shoot/click $((WX+220)) $((WY+595)); sleep 0.6
tools/shoot/click $((WX+220)) $((WY+595)); sleep 0.6
tools/shoot/mmove 2000 800; sleep 0.6

screencapture -v -V21 -R3870,280,570,720 /tmp/takeN.mov &
REC=$!
sleep 1.5

tools/shoot/typer 'Yesterday I have fixed the payment bug. Today I will discuss about it.' 0.055
sleep 0.6
tools/shoot/key 36        # Return
sleep 3.0

tools/shoot/typer '为什么 discuss 后面不能加 about?' 0.045
sleep 0.7
tools/shoot/key 36
wait "$REC"
```

注意：

- `typer` 的真实速度约为 `interval + 22ms/字符`，排期按这个算。
- Return 必须等流式结束；`canSend == false` 时回车会被吞掉。
- 中文可直接用 `typer` 的 Unicode 输入，不需要切换输入法。
- 焦点没进输入框时不要继续打字；先打 `AAA` 抽静帧验证。

### 4.3 录制验收

```bash
ffprobe -v error -show_entries format=duration:stream=width,height,r_frame_rate \
  -of default=noprint_wrappers=1 /tmp/takeN.mov
```

必须确认：

- 标题保持「站会表达练习」，没有后台总结改名。
- 两段发送都有真实 LLM 流式事件。
- 输入折行时刻、回行时刻已量出；当前 take5 为：
  - take 时间约 `5.40s`：1 行 → 2 行
  - take 时间约 `6.95s`：2 行 → 1 行
- 光标没有入镜。
- 关键帧抽图检查底部输入卡、两行状态和最终回答。

---

## 5. 合成管线

### 5.1 不透明母版

```bash
tools/shoot/input_grow_build.sh /tmp/takeN.mov 0.7 /tmp/stage1.mp4 solid
tools/shoot/retime_build.sh /tmp/stage1.mp4 /tmp/final-solid.mp4 solid
```

### 5.2 透明 alpha 母版

```bash
tools/shoot/input_grow_build.sh /tmp/takeN.mov 0.7 /tmp/stage1.mov alpha
tools/shoot/retime_build.sh /tmp/stage1.mov /tmp/final-alpha.mov alpha
```

`alpha` 模式输出 ProRes 4444 中间文件；透明版额外做窗口落影，并把淡入淡出改成淡 alpha。

### 5.3 官网 WebM

```bash
ffmpeg -v error -i /tmp/final-alpha.mov \
  -vf "scale=760:-2:flags=lanczos" -an \
  -c:v libvpx-vp9 -pix_fmt yuva420p -auto-alt-ref 0 \
  -crf 30 -b:v 0 -deadline good -cpu-used 2 -row-mt 1 \
  -y site/assets/hero-loop.webm

ffmpeg -v error -ss 0.30 -i site/assets/hero-loop.webm \
  -frames:v 1 -pix_fmt rgba -y site/assets/hero-poster.png
```

官网 HTML 的顺序必须是：

```html
<source src="assets/hero-loop.webm" type="video/webm">
<source src="assets/hero-loop.mp4" type="video/mp4">
```

并且 hero 里的视频样式不能带边框 / 圆角 / 投影，否则 alpha 视频会重新出现矩形接缝。

---

## 6. 当前效果栈

| 层 | 当前做法 | 关键参数 |
| --- | --- | --- |
| 输入框放大 | 左下角锚定，等比 1.0→1.07x；easeOutBack 过冲约 7.7% 后落位 | 2026-09-22 从 22% 过冲下调，对齐苹果动效规范 5–8%；放大画布仍按 1.22x 预留，仅多留透明边 |
| 外溢光晕 | 卡片 alpha pad 出更大画布后 blur，垫在卡片下面 | blur 20，alpha 峰值约 0.45 |
| 卡片投影 | 另一份更大画布的 blur，顺序必须在光晕之后、卡片之前 | blur 28，alpha 约 0.32 |
| 历史压暗 | 历史向白场淡出到约 50%，当前轮保持满对比；边界随当前轮移动 | `lutrgb=val*0.55+115` |
| 两行让位 | 输入折两行时，列表整体上移 45px，给放大卡片让位 | 动画裁切 y，不是动画 overlay y |
| 重定时 | 打字加速、等待压缩、流式放慢、片尾慢速推近 | 见下方时间表 |
| 官网透明底 | 窗口 alpha 直接浮在页面渐变 / 极光上 | 透明底 RGB 仍保留同色系设计色，兜底不黑 |

### 6.1 当前 stage1 时间轴

| 源时间 | 动作 |
| --- | --- |
| 0.80s | 开始打字 1，卡片开始放大 |
| 4.70s | 输入折成两行，切换到两行卡片链路，并让位 |
| 6.22s | 发送 1，输入清空，卡片缩回 |
| 9.40s | 开始打字 2 |
| 11.60s | 发送 2 |

换 take 后必须重新量这些时间点，不要照抄。

### 6.2 当前重定时表

| 段落 | 源区间 | 速度 | 输出时长 |
| --- | ---: | ---: | ---: |
| 引入 | 0.00–0.80 | 1.00 | 0.80 |
| 打字 1 | 0.80–6.20 | 1.35 | 4.00 |
| 发送 1 | 6.20–6.47 | 1.00 | 0.27 |
| 等首字 1 | 6.47–6.73 | 3.00 | 0.09 |
| 流式 1 | 6.73–7.45 | 0.40 | 1.80 |
| 中段停顿 | 7.45–9.25 | 2.20 | 0.82 |
| 打字 2 | 9.25–11.43 | 1.35 | 1.61 |
| 发送 2 | 11.43–11.87 | 1.00 | 0.44 |
| 流式 2 | 11.87–13.22 | 0.40 | 3.38 |
| 片尾读答案 | 13.22–15.00 | 0.98 + 极慢推近 | 1.82 |

最终 15.03s，裁到 15.00s。

---

## 7. 这次踩过并固化的坑

### 7.1 录制 / 输入

- **AppleScript 打字丢字符**：用 `typer` 的 `keyboardSetUnicodeString`。
- **真实光标会入镜**：点击后立刻 `mmove` 出窗口；不要依赖 `CGDisplayHideCursor`。
- **scrollWheel 事件会 warp 真实光标**：滚动镜头光标必入镜，所以这条片不用滚动镜头。
- **发送后输入框仍保持焦点**：两拍之间不用再点输入框，但 Return 必须等 `canSend` 恢复。
- **`-ss` 后首帧 PTS 偏移导致 `fps=60` 少帧**：必须 `setpts=PTS-STARTPTS,fps=60`，否则 15s 只出 890 帧。

### 7.2 卡片几何

- 输入卡是内容驱动高度：
  - 单行：`838×162 @ capture (80,1206)`
  - 两行：`838×196 @ capture (80,1172)`
  - 底边不动，顶边上移；必须两条链路按时间硬切。
- 回弹峰值 = 1 + 幅度×1.1；放大画布必须按峰值预留边距。旧参数 22% 过冲时按 1.22x 开画布，z>1.20 会把卡片边缘裁掉；现参数 7.7% 沿用大画布，只多留透明边。
- 卡片必须从**原始窗口流**裁，不能从已 `alphamerge` 的窗口裁，否则 alpha 坏掉。
- 每种卡片高度必须用同尺寸圆角遮罩，否则底部 alpha=0 会重影。
- 一个 filter label 只能消费一次；复用先 `split`。

### 7.3 窗口 / 让位

- **压暗遮罩不能当窗口圆角 alpha**：会把窗口下半截整块抠掉。顺序必须是：裁窗口 → 压暗混合 → 套窗口圆角 alpha。
- 让位要动画**裁切 y**，不是动画 overlay 的 y；后者会在过渡中露出未位移内容形成接缝。
- 当前 take 的让位列表源来自滞后 2s 的输入，因为旧 app 折行时会把上一条消息最后一行下缘压掉 6px。这个问题已在 `ffd773f` 修复；**下次重拍后应重新验证，若已消失，可删除这层滞后帧 hack。**

### 7.4 ffmpeg / alpha

- 之前误判“VP9 不能带 alpha”；实际是解码姿势错了。普通解码会输出 `rgb24/yuv420p` 丢 alpha，必须显式：

```bash
ffmpeg -c:v libvpx-vp9 -i input.webm -pix_fmt rgba ...
```

- 编码 alpha：

```bash
-c:v libvpx-vp9 -pix_fmt yuva420p -auto-alt-ref 0
```

- 透明版淡入淡出必须 `fade=...:alpha=1`；淡 luma 会把窗口染黑。
- `crop` 的时间变量是 `t`，`zoompan` 是 `time`，混用报 `Undefined constant`。
- 设计底只能减弱“亮斑”，不能真正消除矩形接缝；最终方案是 alpha 视频 + 页面背景。

### 7.5 产品 bug

`ffd773f` 修复了输入框折行时压掉上一条消息最后一行下缘的问题：

- 根因：窗口按 `minAutoHeight=680` 不缩矮，输入卡变高后 transcript 视口变矮；SwiftUI 不会自动重新贴底。
- 修法：监听 transcript 自己的 `geo.size.height`（不是 `geometry.inputBarHeight`，后者未在 body 建立 @Observable 依赖），在底部时延迟一个 runloop 补 `scrollTo(.bottom)`。
- 修复前 2x 实测：最后一行从 27 行被压成 21 行；修复后恢复 27 行。

---

## 8. 发布前检查清单

### 数据 / 环境

- [ ] `seed_demo_session.py verify` 与拍摄前备份一致。
- [ ] app 真实会话数量、外观、窗口位置恢复。
- [ ] 临时壁纸恢复；被隐藏窗口恢复可见。
- [ ] 没有 API key、私人会话内容进入文档或素材。

### 视频

- [ ] `hero-loop.webm` 存在且 `TAG:alpha_mode=1`。
- [ ] `hero-loop.mp4` 兜底存在，时长 15.00s。
- [ ] `hero-poster.png` `hasAlpha: yes`。
- [ ] `ffprobe`：760×960、60fps、900 帧。
- [ ] 页面截图无矩形边框；中线相邻像素无硬边跳变。
- [ ] hero CSS 对这条视频无 `border/box-shadow/border-radius/background`。
- [ ] 文案使用「演示」，不是「实机演示」。

### 仓库

- [ ] `sh -n tools/shoot/*.sh` 通过。
- [ ] 两级管线可用当前 take 复现，产出 sha256 与入库资产一致。
- [ ] 提交信息说明“哪些是真机、哪些是合成”。

---

## 9. 复现 / 回滚命令

### 本地预览

```bash
cd site
python3 -m http.server 8765
open http://localhost:8765/
```

### 还原真实数据

```bash
python3 tools/shoot/seed_demo_session.py restore --backup /tmp/la-shoot-backup
python3 tools/shoot/seed_demo_session.py verify --backup /tmp/la-shoot-backup
```

### 回滚官网到不透明兜底

把 `site/index.html` 的 `<source>` 顺序改成 MP4 优先，或直接移除 WebM source；但不要给 alpha 视频套矩形卡片样式。

---

## 10. 下一步什么时候改

- **如果产品真的实现“输入框聚焦变大”**：重新实机拍摄，删除输入框放大 / 光晕 / 投影 / 让位等合成层；这条合成片退役。
- **如果用修复后的 app 重拍**：重新量两行 / 回行时刻，并验证滞后 2s 列表源是否还需要。
- **如果 hero 尺寸再调**：当前宽度 480px 是为了让窗口显示尺寸接近旧 hero；改宽度只动 CSS，不要重拍。
- **如果要支持更多浏览器**：优先补 HEVC-alpha 调研；当前 MP4 兜底是稳妥方案，不追求全浏览器透明。
