#!/bin/sh
# 【二级：重定时】把一级合成片按"等待/流式/打字"分别定速。
#   usage: ./retime_build.sh <stage1> <final> [solid|alpha]
#
# 依据（20fps 逐帧差分实测，stage1 时间轴）：
#   发送1 6.20-6.47 → 等首字 6.47-6.73（完全静止）→ 流式 6.73-7.45（0.7s 里分批吐字）
#   中段停顿 7.45-9.25（纯静止）
#   发送2 11.43-11.87 → 流式 11.87-13.22（1.35s）
#   片尾 13.22-15.00（静止，但已有完整答案可读）
#
# 原则：
#   · 等首字、中段停顿 —— 纯空转，重压
#   · 打字 —— 每 0.1s 只变 8-27 像素，信息密度最低，适度加速
#   · 流式 —— 观众唯一要读的内容，放慢
#   · 片尾 —— 不是空转，是读答案的时间，保持慢
#
# 段落表（源 → 速度 → 输出）：
#   A 0.00-0.80 引入      1.00 → 0.80
#   B 0.80-6.20 打字1     1.35 → 4.00
#   C1 6.20-6.47 发送1    1.00 → 0.27
#   C2 6.47-6.73 等首字   3.00 → 0.09   ← 压缩
#   C3 6.73-7.45 流式1    0.40 → 1.80   ← 放慢
#   D 7.45-9.25 中段停顿  2.20 → 0.82   ← 压缩
#   E 9.25-11.43 打字2    1.35 → 1.61
#   F1 11.43-11.87 发送2  1.00 → 0.44
#   F2 11.87-13.22 流式2  0.40 → 3.38   ← 放慢
#   G 13.22-15.00 读答案  0.98 → 1.82，并叠一个 1.00→1.07 的极慢推近（否则这段是死帧）
#   合计 15.03s → 裁到 15.00s
set -e
IN="$1"; OUT="$2"; MODE="${3:-solid}"   # solid | alpha
[ -z "$OUT" ] && { echo "usage: $0 <stage1> <final> [solid|alpha]"; exit 2; }

FG="[0:v]split=10[s0][s1][s2][s3][s4][s5][s6][s7][s8][s9];"
FG="${FG}[s0]trim=start=0:end=0.80,setpts=PTS-STARTPTS[p0];"
FG="${FG}[s1]trim=start=0.80:end=6.20,setpts=(PTS-STARTPTS)/1.35[p1];"
FG="${FG}[s2]trim=start=6.20:end=6.47,setpts=PTS-STARTPTS[p2];"
FG="${FG}[s3]trim=start=6.47:end=6.73,setpts=(PTS-STARTPTS)/3.00[p3];"
FG="${FG}[s4]trim=start=6.73:end=7.45,setpts=(PTS-STARTPTS)/0.40[p4];"
FG="${FG}[s5]trim=start=7.45:end=9.25,setpts=(PTS-STARTPTS)/2.20[p5];"
FG="${FG}[s6]trim=start=9.25:end=11.43,setpts=(PTS-STARTPTS)/1.35[p6];"
FG="${FG}[s7]trim=start=11.43:end=11.87,setpts=PTS-STARTPTS[p7];"
FG="${FG}[s8]trim=start=11.87:end=13.22,setpts=(PTS-STARTPTS)/0.40[p8];"
FG="${FG}[s9]trim=start=13.22:end=15.00,setpts=(PTS-STARTPTS)/0.98,"
FG="${FG}zoompan=z='1+0.07*min(max(time/1.82\\,0)\\,1)':x='(iw-iw/zoom)/2':y='(ih-ih/zoom)*0.5':d=1:s=1140x1440:fps=60[p9];"
FG="${FG}[p0][p1][p2][p3][p4][p5][p6][p7][p8][p9]concat=n=10:v=1:a=0,fps=60,"
if [ "$MODE" = "alpha" ]; then
  # 透明版要淡的是 alpha（淡 luma 会把窗口变成黑的）
  FG="${FG}fade=t=in:st=0:d=0.3:alpha=1,fade=t=out:st=14.5:d=0.5:alpha=1[out]"
else
  FG="${FG}fade=t=in:st=0:d=0.3,fade=t=out:st=14.5:d=0.5[out]"
fi

ffmpeg -v error -i "$IN" -filter_complex "$FG" -map "[out]" -an \
  $(if [ "$MODE" = "alpha" ]; then echo "-c:v prores_ks -profile:v 4444 -pix_fmt yuva444p10le"; else echo "-c:v libx264 -preset slow -crf 19 -pix_fmt yuv420p -movflags +faststart"; fi) -t 15 "$OUT" -y
echo "wrote $OUT"
