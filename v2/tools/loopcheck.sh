#!/bin/bash
# Чи замкнена петля: середня різниця першого й останнього кадру (0–255). < 6 = замкнена.
set -e
for f in "$@"; do
  ffmpeg -v error -y -i "$f" -vf "select=eq(n\,0),scale=128:128" -frames:v 1 /tmp/lc_first.png
  ffmpeg -v error -y -sseof -0.1 -i "$f" -vf "scale=128:128" -frames:v 1 -update 1 /tmp/lc_last.png
  python3 - "$f" <<'PY'
import sys, struct, zlib
def png(p):
    d=open(p,'rb').read(); pos=8; idat=b''
    while pos<len(d):
        L=struct.unpack('>I',d[pos:pos+4])[0]; t=d[pos+4:pos+8]; c=d[pos+8:pos+8+L]
        if t==b'IHDR': w,h,bd,ct=struct.unpack('>IIBB',c[:10])
        if t==b'IDAT': idat+=c
        pos+=12+L
    raw=zlib.decompress(idat); bpp=3 if ct==2 else 4; stride=w*bpp; out=[]; prev=bytearray(stride); i=0
    for y in range(h):
        f=raw[i]; i+=1; line=bytearray(raw[i:i+stride]); i+=stride
        for x in range(stride):
            a=line[x-bpp] if x>=bpp else 0; b=prev[x]; c=prev[x-bpp] if x>=bpp else 0
            if f==1: line[x]=(line[x]+a)&255
            elif f==2: line[x]=(line[x]+b)&255
            elif f==3: line[x]=(line[x]+(a+b)//2)&255
            elif f==4:
                p=a+b-c; pa,pb,pc=abs(p-a),abs(p-b),abs(p-c)
                line[x]=(line[x]+(a if pa<=pb and pa<=pc else b if pb<=pc else c))&255
        out.append(bytes(line)); prev=line
    return b''.join(out)
A=png('/tmp/lc_first.png'); B=png('/tmp/lc_last.png')
m=sum(abs(A[i]-B[i]) for i in range(len(A)))/len(A)
print(f"{sys.argv[1]}: {m:.1f}/255  {'петля ✓' if m<6 else 'петля ✗'}")
PY
done
