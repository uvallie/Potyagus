#!/bin/bash
# Контактний аркуш кліпу: 12 кадрів (2 fps) в один PNG поруч із файлом.
for f in "$@"; do ffmpeg -v error -y -i "$f" -vf "fps=2,scale=256:-1,tile=6x2" -frames:v 1 "${f%.mp4}-sheet.png" && echo "✓ ${f%.mp4}-sheet.png"; done
