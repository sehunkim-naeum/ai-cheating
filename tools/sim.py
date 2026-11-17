# main.dart의 _analyze() 로직을 그대로 옮겨, 가상 교실에서 기기 4종의 점수를 계산
import math, random
random.seed(1)
rows, cols, gx, gy, near = 5, 6, 1.0, 1.1, -65
maxX, maxY = cols*gx, rows*gy
# 감독관 경로: 세로 통로 7개를 지그재그로 2바퀴, 걸음 0.65m/0.6s
pts=[]
for lap in range(2):
    for a in range(cols+1):
        x=a*gx; ys=[i*0.65 for i in range(int(maxY/0.65)+1)]
        if a%2: ys=ys[::-1]
        pts += [(x,y) for y in ys]
        if a<cols:  # 앞/뒤 가로 이동
            y=ys[-1]; pts += [(x+gx*k/2,y) for k in (1,)]
t=0; path=[]
for p in pts: path.append((t,p)); t+=0.6
T=t
devs={ # 이름: (x,y, 1m 세기, 벽 감쇠)
 'B-3 귀속 이어폰':(2.5*gx,1.5*gy,-62,0),
 'D-1 가방 속 폰':(0.5*gx,3.5*gy,-56,0),
 '옆 교실 폰(벽 너머 3m)':(-3.0,2.5,-56,10),
 '복도 공유기':(3.0,-2.5,-40,10),
}
def rssi(d,p):
    x,y,tx,wall=d; dist=max(0.3,math.hypot(x-p[0],y-p[1]))
    return round(tx-25*math.log10(dist)-wall+random.gauss(0,4))
for name,d in devs.items():
    s=[]
    for (t,p) in path:
        for k in range(3):  # 0.2초마다 광고 수신, 일부 유실
            if random.random()<0.6:
                r=rssi(d,p)
                if r>-95: s.append((p[0],p[1],r,t+k*0.2))
    peak=max(r for _,_,r,_ in s)
    if peak<near: print(f'{name:22s} 최대 {peak}dBm → 원거리 제외'); continue
    w=sum(10**(r/10) for *_,r,_ in s); ex=sum(x*10**(r/10) for x,_,r,_ in s)/w; ey=sum(y*10**(r/10) for _,y,r,_ in s)/w
    xs=[math.log(max(.3,math.hypot(x-ex,y-ey))) for x,y,_,_ in s]; ys=[r for *_,r,_ in s]
    mx=sum(xs)/len(xs); my=sum(ys)/len(ys)
    cov=sum((a-mx)*(b-my) for a,b in zip(xs,ys)); vx=sum((a-mx)**2 for a in xs); vy=sum((b-my)**2 for b in ys)
    corr=cov/math.sqrt(vx*vy)
    rng=peak-round(sorted(ys)[int(len(ys)*.2)])
    peaks=[];cur=None;last=None
    for x,y,r,t in s:
        if r<peak-6: continue
        if last is not None and t-last>5 and cur: peaks.append(cur[:2]);cur=None
        if cur is None or r>cur[2]: cur=(x,y,r)
        last=t
    if cur: peaks.append(cur[:2])
    cons=sum(1 for px,py in peaks if math.hypot(px-ex,py-ey)<=1.0)
    rep=min(len(peaks),3)/3*cons/len(peaks)
    persist=1.0
    peakS=min(1,max(0,(peak-near)/(abs(near)-40))); locS=min(1,max(0,-corr)); rangeS=min(1,max(0,(rng-5)/15))
    kw=1.0 if '이어폰' in name else 0.9 if '폰' in name else 0.4
    score=100*kw*(.25*peakS+.25*locS+.2*rangeS+.15*rep+.15*persist)
    seatC=min(cols-1,max(0,round(ex/gx-.5))); seatR=min(rows-1,max(0,round(ey/gy-.5)))
    print(f'{name:22s} 최대 {peak}dBm 변화폭 {rng}dB 위치일치 {-corr:.2f} 반복피크 {len(peaks)}회(일치 {cons}) 추정자리 {chr(65+seatR)}-{seatC+1} → {score:.0f}점')
