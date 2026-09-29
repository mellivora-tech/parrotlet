#!/bin/sh
# 【一级：合成】输入框聚焦变大（左下锚定 + 回弹）+ 外溢光晕 + 投影 + 历史压暗（屏幕区域录制版）
#   usage: ./input_grow_build.sh <take.mov> <ss秒> <stage1> [solid|alpha]
#   再跑 ./retime_build.sh <stage1> <final> [solid|alpha]
#   solid = 不透明设计底；alpha = 透明底 + 窗口落影（后续可转 WebM/VP9 alpha）
#
# 录前准备（必须）：
#   1. 换干净壁纸："/System/Library/Desktop Pictures/Solid Colors/Space Gray.png"
#      （.madesktop 是动态壁纸引用，set picture 对它无效）
#   2. 清空窗口周围：临时 set visible of process "Ghostty" to false
#   3. 窗口左上角 (3900,300)，录制区域 screencapture -v -R3870,280,570,720
#      → 画面 1140x1440 @2x，窗口在 (60,40)，边距 左60 右200 上40 下40
#      （右边距必须先算够：两行卡放大 1.2x 向右溢出 146px）
#
# 放大锚点 = 输入卡左下角。卡片高度内容驱动：单行 163px / 两行 196px。
#   ⚠️ 回弹峰值到 1.22x，所以放大画布按 1.22x 开（1022x198 / 1022x239），
#      否则 z>1.20 时会把卡片边缘裁掉。
#   单行卡 838x162 @ capture (80,1206) → pad 1022:198:0:36 → overlay (80,1170)
#   两行卡 838x196 @ capture (80,1172) → pad 1022:239:0:43 → overlay (80,1129)
#   切换点 4.70 / 6.22
# 让位：两行卡放大后顶边在 capture 1133，上一条消息第 2 行在 1151..1177，
#   必须把它上移 45px。列表源取自滞后 2s 的帧（app 自己折行时压掉了那行下缘 6px）。
#   动画用【动画裁切 y】而不是动画 overlay y —— 后者会在过渡中露出一段未位移的内容形成接缝：
#     crop y = 140 + 45*ease(t)   overlay 固定 (80,140)
# 光晕/投影：都从卡片 alpha pad 出更大的画布再 blur；光晕画布 1102x278 / 1102x319。
set -e
TAKE="$1"; SS="${2:-0.7}"; OUT="$3"; MODE="${4:-solid}"   # solid | alpha
[ -z "$OUT" ] && { echo "usage: $0 <take.mov> <ss> <out> [solid|alpha]"; exit 2; }
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

python3 - "$TMP" <<'PY'
import sys, numpy as np
out = sys.argv[1]
def rounded_pgm(path, W, H, R):
    yy, xx = np.mgrid[0:H, 0:W].astype(np.float32)
    dx = np.abs(xx-(W-1)/2) - ((W-1)/2 - R)
    dy = np.abs(yy-(H-1)/2) - ((H-1)/2 - R)
    d = np.hypot(np.maximum(dx,0), np.maximum(dy,0)) + np.minimum(np.maximum(dx,dy),0) - R
    a = np.clip(0.5 - d, 0, 1)
    with open(path,'wb') as f:
        f.write(b'P5\n%d %d\n255\n' % (W,H)); f.write((a*255).astype(np.uint8).tobytes())
rounded_pgm(out + "/winmask.pgm", 880, 1360, 30)   # 整窗圆角（从录制里抠窗口用）
rounded_pgm(out + "/cardA.pgm", 838, 162, 18)
rounded_pgm(out + "/cardB.pgm", 838, 196, 18)

# ---- 设计底：对齐官网 hero 那块的实际底色（实测 #1b1a39 上 → #242150 下 + 右上柔光）----
# 为什么不用真实桌面：桌面壁纸的颜色没法跟页面的渐变+极光背景对齐，会在页面上读作一块亮斑。
import math
Wb, Hb = 1140, 1440
yy, xx = np.mgrid[0:Hb, 0:Wb].astype(np.float32)
t = yy / (Hb - 1)
c0 = np.array([0x1b, 0x1a, 0x39], np.float32)
c1 = np.array([0x24, 0x21, 0x50], np.float32)
bg = c0[None, None, :] * (1 - t[..., None]) + c1[None, None, :] * t[..., None]
gx, gy, gr = Wb * 0.86, Hb * 0.18, max(Wb, Hb) * 0.55
gd = np.sqrt(((xx - gx) / gr) ** 2 + ((yy - gy) / gr) ** 2)
bg += np.array([0x2a, 0x16, 0x3e], np.float32)[None, None, :] * (np.clip(1 - gd, 0, 1) ** 2 * 0.30)[..., None]
with open(out + "/brandbg.ppm", "wb") as f:
    f.write(b"P6\n%d %d\n255\n" % (Wb, Hb))
    f.write(np.clip(bg, 0, 255).astype(np.uint8).tobytes())

def clamp(t0, t1):
    return f"min(max((time-{t0})/{t1-t0}\\,0)\\,1)"
def smooth(t0, t1):
    p = clamp(t0, t1)
    return f"pow({p}\\,2)*(3-2*{p})"
def backout(t0, t1):
    # easeOutBack：u=0→1 过冲到 1.1 再收回（配合 0.20 的幅度 → 峰值 1.22x）
    u = clamp(t0, t1)
    return f"(1+2.70158*pow(({u})-1\\,3)+1.70158*pow(({u})-1\\,2))"
# 两次放大用回弹，两次缩回用平滑
z = f"1.0+0.20*{backout(0.80,1.12)}-0.20*{smooth(6.22,6.42)}+0.20*{backout(9.40,9.72)}-0.20*{smooth(11.60,11.80)}"
open(out + "/k_expr.txt","w").write(z)

# 让位动画用的裁切 y：140 → 185（smoothstep，0.18s）
# 注意：crop 的时间变量是 t，zoompan 才是 time
def clamp_t(t0, t1):
    return f"min(max((t-{t0})/{t1-t0}\\,0)\\,1)"
def smooth_t(t0, t1):
    q = clamp_t(t0, t1)
    return f"pow({q}\\,2)*(3-2*{q})"
open(out + "/shift_expr.txt","w").write(f"140+45*{smooth_t(4.70,4.88)}")

W,H,FPS,DUR,RAMP = 8,1360,60,15.0,170
KEYS = [(0.00,930),(6.05,930),(6.70,860),(9.25,860),(9.75,940),
        (11.35,940),(11.95,800),(12.60,790),(13.30,520),(15.00,500)]
def top_at(t):
    if t<=KEYS[0][0]: return KEYS[0][1]
    for i in range(len(KEYS)-1):
        t0,v0=KEYS[i]; t1,v1=KEYS[i+1]
        if t0<=t<=t1:
            u=0.0 if t1==t0 else (t-t0)/(t1-t0); s=u*u*(3-2*u)
            return v0+(v1-v0)*s
    return KEYS[-1][1]
with open(out + "/mask.raw","wb") as f:
    for i in range(int(FPS*DUR)):
        top=top_at(i/FPS); buf=bytearray()
        for y in range(H):
            if y>=top: v=0
            elif y<=top-RAMP: v=255
            else:
                u=(top-y)/RAMP; v=int(round(255*u*u*(3-2*u)))
            buf += bytes((v,))*W
        f.write(buf)
PY
K=$(cat "$TMP/k_expr.txt"); SH=$(cat "$TMP/shift_expr.txt")

FG="[0:v]setpts=PTS-STARTPTS,fps=60[cap];"
FG="${FG}[3:v]setpts=PTS-STARTPTS+2/TB,tpad=start_duration=2:start_mode=clone,crop=880:993:80:'${SH}'[Blist];"
FG="${FG}[cap]split=2[capWin0][capCard];"
# 先裁出窗口区域再做压暗（压暗遮罩是 880x1360，必须和它同尺寸才能 alphamerge）
FG="${FG}[capWin0]crop=880:1360:60:40[capwin];"
FG="${FG}[capwin]split=2[capw0][capwf];"
FG="${FG}[capwf]format=gbrp,lutrgb=r='val*0.55+115':g='val*0.55+115':b='val*0.55+115',format=rgba[fadedRGB];"
FG="${FG}[4:v]scale=880:1360:flags=bilinear,format=gray[fmask];"
FG="${FG}[fadedRGB][fmask]alphamerge[fadedA];"
FG="${FG}[capw0][fadedA]overlay=format=auto[winFadedRGB];"
# 再套窗口圆角 alpha。顺序不能反：拿压暗遮罩当窗口 alpha 会把窗口下半截抠没（踩过）
FG="${FG}[5:v]format=gray[winmask];"
FG="${FG}[winFadedRGB][winmask]alphamerge[winA];"
# 设计底 + 窗口
if [ "$MODE" = "alpha" ]; then PIXFMT="rgba"; else PIXFMT="yuv420p"; fi
FG="${FG}[6:v]format=rgb24,format=rgba[bgRGB];"
if [ "$MODE" = "alpha" ]; then
  # 同色 + 全透明：支持 alpha 的浏览器透出页面极光，不支持的显示同色（兜底不丑）
  FG="${FG}[bgRGB]colorchannelmixer=aa=0[bgT];"
  # 窗口落影（透明底上窗口不能是平的）：把窗口 alpha 垫大一圈再模糊，压暗后放窗口下面
  FG="${FG}[5:v]format=gray,pad=1000:1480:60:60:color=black,boxblur=26:2,lut=y='val*0.45'[wshm];"
  FG="${FG}color=c=0x000000:s=1000x1480:r=60[wshc];"
  FG="${FG}[wshc][wshm]alphamerge[wshRGBA];"
  FG="${FG}[bgT][wshRGBA]overlay=x=6:y=-10:format=auto:eof_action=pass[stageS];"
  FG="${FG}[stageS][winA]overlay=x=60:y=40:format=auto:shortest=1[faded];"
else
  FG="${FG}[bgRGB]null[bgS];"
  FG="${FG}[bgS][winA]overlay=x=60:y=40:format=auto:shortest=1[faded];"
fi
# 卡片链路用的窗口必须来自【原始录制】（不带 alpha、不带压暗）
FG="${FG}[capCard]crop=880:1360:60:40[winRaw];"
FG="${FG}[winRaw]split=2[cwA][cwB];"
FG="${FG}[faded]split=2[bA][bB];"
# ---- 单行链 ----
FG="${FG}[1:v]pad=1022:198:0:36:color=black,zoompan=z='${K}':x='0':y='ih-ih/zoom':d=1:s=1022x198:fps=60,split=2[a1][a2];"
FG="${FG}[cwA]crop=838:162:20:1166,pad=1022:198:0:36:color=black,zoompan=z='${K}':x='0':y='ih-ih/zoom':d=1:s=1022x198:fps=60[Acard];"
FG="${FG}[Acard][a1]alphamerge[AcardRGBA];"
FG="${FG}[a2]format=gray,split=2[a2g][a2s];"
FG="${FG}[a2g]pad=1102:278:40:40:color=black,boxblur=20:2,lut=y='val*0.45'[Aglowmask];"
FG="${FG}color=c=0x6199f6:s=1102x278:r=60[Agcol];"
FG="${FG}[Agcol][Aglowmask]alphamerge[AglowRGBA];"
FG="${FG}[a2s]pad=1102:278:40:40:color=black,boxblur=28:2,lut=y='val*0.32'[Ashadowmask];"
FG="${FG}color=c=0x000000:s=1102x278:r=60[Ashcol];"
FG="${FG}[Ashcol][Ashadowmask]alphamerge[AshadowRGBA];"
FG="${FG}[bA][AglowRGBA]overlay=x=40:y=1130:format=auto:eof_action=pass[sA0];"
FG="${FG}[sA0][AshadowRGBA]overlay=x=50:y=1146:format=auto:eof_action=pass[sA1];"
FG="${FG}[sA1][AcardRGBA]overlay=x=80:y=1170:format=auto:shortest=1[sA2];"
FG="${FG}[sA2]format=${PIXFMT}[outA];"
# ---- 两行链 ----
FG="${FG}[2:v]pad=1022:239:0:43:color=black,zoompan=z='${K}':x='0':y='ih-ih/zoom':d=1:s=1022x239:fps=60,split=2[b1][b2];"
FG="${FG}[cwB]crop=838:196:20:1132,pad=1022:239:0:43:color=black,zoompan=z='${K}':x='0':y='ih-ih/zoom':d=1:s=1022x239:fps=60[Bcard];"
FG="${FG}[Bcard][b1]alphamerge[BcardRGBA];"
FG="${FG}[b2]format=gray,split=2[b2g][b2s];"
FG="${FG}[b2g]pad=1102:319:40:40:color=black,boxblur=20:2,lut=y='val*0.45'[Bglowmask];"
FG="${FG}color=c=0x6199f6:s=1102x319:r=60[Bgcol];"
FG="${FG}[Bgcol][Bglowmask]alphamerge[BglowRGBA];"
FG="${FG}[b2s]pad=1102:319:40:40:color=black,boxblur=28:2,lut=y='val*0.32'[Bshadowmask];"
FG="${FG}color=c=0x000000:s=1102x319:r=60[Bshcol];"
FG="${FG}[Bshcol][Bshadowmask]alphamerge[BshadowRGBA];"
FG="${FG}[bB][Blist]overlay=x=80:y=140:format=auto:shortest=1[sB0];"
FG="${FG}[sB0][BglowRGBA]overlay=x=40:y=1089:format=auto:eof_action=pass[sB1];"
FG="${FG}[sB1][BshadowRGBA]overlay=x=50:y=1105:format=auto:eof_action=pass[sB2];"
FG="${FG}[sB2][BcardRGBA]overlay=x=80:y=1129:format=auto:shortest=1[sB3];"
FG="${FG}[sB3]format=${PIXFMT}[outB];"
FG="${FG}[outA][outB]overlay=enable='between(t,4.70,6.22)':format=auto:shortest=1[sw];"
FG="${FG}[sw]format=${PIXFMT}[out]"

ffmpeg -v error -ss "$SS" -t 16 -i "$TAKE" \
  -loop 1 -framerate 60 -i "$TMP/cardA.pgm" \
  -loop 1 -framerate 60 -i "$TMP/cardB.pgm" \
  -ss "$SS" -t 16 -i "$TAKE" \
  -f rawvideo -pix_fmt gray -s 8x1360 -r 60 -i "$TMP/mask.raw" \
  -loop 1 -framerate 60 -i "$TMP/winmask.pgm" \
  -loop 1 -framerate 60 -i "$TMP/brandbg.ppm" \
  -filter_complex "$FG" -map "[out]" -an \
  $(if [ "$MODE" = "alpha" ]; then
      echo "-c:v prores_ks -profile:v 4444 -pix_fmt yuva444p10le"
    else
      echo "-c:v libx264 -preset slow -crf 17 -pix_fmt yuv420p"
    fi) -t 15 "$OUT" -y
echo "stage1 wrote $OUT"
