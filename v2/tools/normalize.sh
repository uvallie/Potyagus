#!/bin/bash
# Нормалізація кліпів для апки: фон → точно #7DB262, теги bt709, без аудіо (звук окремо у v2/audio/).
# Використання: v2/tools/normalize.sh v2/clips/*.mp4   → web/clips/<name>.mp4
set -e
T_R=127; T_G=181; T_B=101   # ціль зі зсувом: після декодування в WebKit виходить рівно 125,178,98
for f in "$@"; do
  n=$(basename "${f%.mp4}")
  hex=$(ffmpeg -v error -i "$f" -frames:v 1 -vf "crop=20:20:5:5,scale=1:1" -f rawvideo -pix_fmt rgb24 - | xxd -p)
  r=$((16#${hex:0:2})); g=$((16#${hex:2:2})); b=$((16#${hex:4:2}))
  gr=$(python3 -c "print(round($T_R/$r,4))"); gg=$(python3 -c "print(round($T_G/$g,4))"); gb=$(python3 -c "print(round($T_B/$b,4))")
  ffmpeg -v error -y -i "$f" -an \
    -vf "lutrgb=r=val*$gr:g=val*$gg:b=val*$gb,format=yuv420p" \
    -c:v libx264 -crf 18 -preset slow -movflags +faststart \
    -color_primaries bt709 -color_trc bt709 -colorspace bt709 -color_range tv \
    "web/clips/$n.mp4"
  if ffprobe -v error -select_streams a -show_entries stream=codec_name -of csv=p=0 "$f" | grep -q .; then
    ffmpeg -v error -y -i "$f" -vn -c:a copy "v2/audio/$n.m4a"
  fi
  out=$(ffmpeg -v error -i "web/clips/$n.mp4" -frames:v 1 -vf "crop=20:20:5:5,scale=1:1" -f rawvideo -pix_fmt rgb24 - | xxd -p)
  echo "$n: $hex → $out (gain $gr/$gg/$gb)"
done
