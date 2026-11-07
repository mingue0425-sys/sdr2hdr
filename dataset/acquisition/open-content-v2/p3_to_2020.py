"""Exact per-pixel PQ P3-D65 -> PQ BT.2020 on gbrp16le frames (stdin -> stdout)."""
import sys, numpy as np
W,H=int(sys.argv[1]),int(sys.argv[2])
M=np.array([[0.753833,0.198597,0.04757],[0.045744,0.941777,0.012479],[-0.00121,0.017602,0.983609]])
m1,m2,c1,c2,c3=2610/16384,2523/4096*128,3424/4096,2413/4096*32,2392/4096*32
def eotf(v):
    p=np.power(np.clip(v,0,1),1/m2); return np.power(np.maximum(p-c1,0)/(c2-c3*p),1/m1)
def oetf(l):
    p=np.power(np.clip(l,0,1),m1); return np.power((c1+c2*p)/(1+c3*p),m2)
frame=W*H*3*2; n=0
inp=sys.stdin.buffer; out=sys.stdout.buffer
while True:
    buf=inp.read(frame)
    if len(buf)<frame: break
    planes=np.frombuffer(buf,dtype='<u2').reshape(3,H*W).astype(np.float64)/65535.0  # G,B,R
    rgb=np.stack([planes[2],planes[0],planes[1]])
    lin=M@eotf(rgb)
    o=np.round(oetf(lin)*65535.0).astype('<u2')
    out.write(np.stack([o[1],o[2],o[0]]).tobytes()); n+=1
sys.stderr.write(f'converted {n} frames\n')
