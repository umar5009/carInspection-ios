from PIL import Image, ImageDraw, ImageFilter, ImageChops
import math
S=4096
def lerp(a,b,t): return tuple(int(a[i]+(b[i]-a[i])*t) for i in range(3))
def background(size, transparent=False):
    img=Image.new("RGBA",(size,size))
    top=(12,24,52); bot=(4,60,78)
    px=img.load()
    grad=Image.linear_gradient("L").resize((size,size))
    base=Image.composite(Image.new("RGBA",(size,size),bot+(255,)),Image.new("RGBA",(size,size),top+(255,)),grad)
    # radial glow
    glow=Image.new("L",(size,size),0); d=ImageDraw.Draw(glow)
    d.ellipse([size*0.15,size*0.25,size*0.85,size*0.95],fill=150)
    glow=glow.filter(ImageFilter.GaussianBlur(size*0.12))
    mint=Image.new("RGBA",(size,size),(0,224,184,255))
    base=Image.composite(mint,base,glow.point(lambda v:int(v*0.35)))
    return base

def car_mask(size, cx, cy, w):
    m=Image.new("L",(size,size),0); d=ImageDraw.Draw(m)
    h=w*0.38
    x0=cx-w/2; y0=cy-h/2
    def P(x,y): return (x0+x*w, y0+y*h)
    body=[P(0.02,0.60),P(0.06,0.46),P(0.24,0.38),P(0.36,0.35),P(0.46,0.10),P(0.52,0.05),P(0.70,0.05),P(0.79,0.12),P(0.88,0.34),P(0.97,0.40),P(0.99,0.55),P(0.98,0.80),P(0.02,0.80)]
    d.polygon(body,fill=255)
    # round nose/tail
    r=h*0.18
    d.rounded_rectangle([x0+0.01*w,y0+0.46*h,x0+0.99*w,y0+0.82*h],radius=r,fill=255)
    # windows (cut)
    win=[P(0.43,0.35),P(0.495,0.14),P(0.59,0.12),P(0.59,0.35)]
    win2=[P(0.62,0.35),P(0.62,0.12),P(0.69,0.12),P(0.78,0.35)]
    d.polygon(win,fill=0); d.polygon(win2,fill=0)
    # wheel arches (cut) and wheels
    for wx in (0.22,0.79):
        R=h*0.235
        cxw,cyw=x0+wx*w,y0+0.80*h
        d.ellipse([cxw-R*1.18,cyw-R*1.18,cxw+R*1.18,cyw+R*1.18],fill=0)
        d.ellipse([cxw-R,cyw-R,cxw+R,cyw+R],fill=255)
        d.ellipse([cxw-R*0.45,cyw-R*0.45,cxw+R*0.45,cyw+R*0.45],fill=0)
    return m

def brackets(size, box, color, width):
    lay=Image.new("RGBA",(size,size),(0,0,0,0)); d=ImageDraw.Draw(lay)
    x0,y0,x1,y1=box; L=(x1-x0)*0.17
    for (cx,cy,dx,dy) in [(x0,y0,1,1),(x1,y0,-1,1),(x0,y1,1,-1),(x1,y1,-1,-1)]:
        d.line([(cx,cy+dy*L),(cx,cy),(cx+dx*L,cy)],fill=color,width=width,joint="curve")
        for p in [(cx,cy+dy*L),(cx+dx*L,cy),(cx,cy)]:
            d.ellipse([p[0]-width/2,p[1]-width/2,p[0]+width/2,p[1]+width/2],fill=color)
    return lay

def compose(size, with_bg=True):
    base=background(size) if with_bg else Image.new("RGBA",(size,size),(0,0,0,0))
    cm=car_mask(size,size*0.5,size*0.55,size*0.66)
    white=Image.new("RGBA",(size,size),(245,250,255,255))
    base=Image.composite(white,base,cm)
    # scan line: glow band across the car, tinted mint on car pixels
    sy=size*0.545
    band=Image.new("L",(size,size),0); d=ImageDraw.Draw(band)
    d.rectangle([size*0.12,sy-size*0.006,size*0.88,sy+size*0.006],fill=255)
    bandglow=band.filter(ImageFilter.GaussianBlur(size*0.02))
    mint=Image.new("RGBA",(size,size),(0,230,190,255))
    base=Image.composite(mint,base,ImageChops.add(band,bandglow.point(lambda v:int(v*0.9))))
    # tint car below scan line slightly mint (already-scanned area)
    lower=Image.new("L",(size,size),0); ImageDraw.Draw(lower).rectangle([0,sy,size,size],fill=70)
    base=Image.composite(mint,base,ImageChops.multiply(cm,lower))
    # brackets
    b=brackets(size,(size*0.14,size*0.22,size*0.86,size*0.86),(0,224,184,255),int(size*0.028))
    base=Image.alpha_composite(base,b)
    # check badge
    d=ImageDraw.Draw(base)
    cx,cy,r=size*0.70,size*0.33,size*0.075
    d.ellipse([cx-r,cy-r,cx+r,cy+r],fill=(0,224,184,255))
    d.line([(cx-r*0.45,cy+r*0.02),(cx-r*0.1,cy+r*0.38),(cx+r*0.5,cy-r*0.35)],fill=(8,28,56,255),width=int(size*0.022),joint="curve")
    return base

icon=compose(S).convert("RGB").resize((1024,1024),Image.LANCZOS)
icon.save("AppIcon-1024.png")
logo=compose(S).resize((600,600),Image.LANCZOS)
# rounded logo for launch
mask=Image.new("L",(600,600),0); ImageDraw.Draw(mask).rounded_rectangle([0,0,599,599],radius=135,fill=255)
logo.putalpha(mask); logo.save("LaunchLogo.png")
