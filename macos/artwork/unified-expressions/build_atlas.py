#!/usr/bin/env python3
"""Technically extract six generated poses per sheet and pack the supplement.

Only Pillow is required. Source RGBA is never recolored or thresholded. An alpha
threshold identifies separate subjects and their crop bounds, not output alpha.
A common scale per row preserves pose-to-pose height changes. Generated sheets
need not respect their nominal 512px grid: complete connected subjects are used.
"""
from __future__ import annotations
import argparse
from collections import deque
import hashlib
import json
from pathlib import Path
import statistics
import struct
from PIL import Image, ImageDraw, ImageFont, PngImagePlugin

NAMES = ['smile-closed', 'panic', 'guilty', 'stone']
TIMINGS = {
 'smile-closed': [400,200,200,240,240,900],
 'panic': [160,160,160,180,180,480],
 'guilty': [750,220,180,280,220,1050],
 'stone': [1000,200,400,220,300,1300],
}
CELL=(192,208)
FOOT=202
NOMINAL_HEIGHT=173
THRESHOLD=128
PADDING=2


def components(alpha: Image.Image):
    w,h=alpha.size
    mask=bytearray(alpha.point(lambda v: 1 if v>=THRESHOLD else 0).tobytes())
    found=[]
    for start,value in enumerate(mask):
        if not value: continue
        q=deque([start]); mask[start]=0
        points=[]; left=w; top=h; right=bottom=0
        while q:
            p=q.popleft(); points.append(p)
            y,x=divmod(p,w)
            left=min(left,x); right=max(right,x+1); top=min(top,y); bottom=max(bottom,y+1)
            for yy in range(max(0,y-1),min(h,y+2)):
                base=yy*w
                for xx in range(max(0,x-1),min(w,x+2)):
                    n=base+xx
                    if mask[n]: mask[n]=0; q.append(n)
        found.append({'count':len(points),'bbox':(left,top,right,bottom),'points':points})
    return sorted(found,key=lambda c:c['count'],reverse=True)


def png(path: Path, im: Image.Image):
    info=PngImagePlugin.PngInfo(); info.add(b'sRGB',b'\x00')
    im.save(path, pnginfo=info, optimize=True)


def extract(source: Path):
    im=Image.open(source).convert('RGBA')
    if im.size!=(1536,1024): raise ValueError(f'Unexpected source size: {source} {im.size}')
    alpha=im.getchannel('A')
    comps=components(alpha)
    majors=[c for c in comps if c['count']>=30000]
    if len(majors)!=6: raise ValueError(f'{source.name}: expected six subjects, got {len(majors)}')
    majors.sort(key=lambda c: ((c['bbox'][1]+c['bbox'][3])//1024, (c['bbox'][0]+c['bbox'][2])/2))
    if any((c['bbox'][1]+c['bbox'][3])/2>=512 for c in majors[:3]) or any((c['bbox'][1]+c['bbox'][3])/2<512 for c in majors[3:]):
        raise ValueError('Subjects cannot be assigned to two complete rows')
    crops=[]; reports=[]
    for i,c in enumerate(majors):
        x0,y0,x1,y1=c['bbox']
        crop_box=(max(0,x0-PADDING),max(0,y0-PADDING),min(im.width,x1+PADDING),min(im.height,y1+PADDING))
        crop=im.crop(crop_box)
        # Keep every alpha value within the technical crop unchanged. The crop
        # trims low-alpha far-field speckle instead of remaking a transparency mask.
        a=crop.getchannel('A'); bb=a.getbbox()
        crop=crop.crop(bb)
        box=(crop_box[0]+bb[0],crop_box[1]+bb[1],crop_box[0]+bb[2],crop_box[1]+bb[3])
        core_h=y1-y0
        # Use the center of the high-alpha shoe band (lowest 10% of the body),
        # rather than the variable hair silhouette, as the stable horizontal anchor.
        band_y=y1-max(8,round(core_h*0.10))
        feet=alpha.crop((x0,band_y,x1,y1)).point(lambda v:255 if v>=THRESHOLD else 0).getbbox()
        feet_center=x0+(feet[0]+feet[2])/2 if feet else (x0+x1)/2
        crops.append((crop,feet_center-box[0]))
        nominal=(i%3*512,i//3*512,(i%3+1)*512,(i//3+1)*512)
        reports.append({'frame':i,'componentAreaAtAlpha128':c['count'],'coreBBox':list(c['bbox']),
                        'retainedCropBBox':list(box),'nominalCell':list(nominal),
                        'crossesNominalCell':not(nominal[0]<=x0 and nominal[1]<=y0 and x1<=nominal[2] and y1<=nominal[3]),
                        'coreHeight':core_h,'retainedHeight':crop.height,'feetCenterSourceX':feet_center,
                        'retainedAlphaExtrema':list(a.getextrema())})
    return crops, reports, comps, im


def font(size):
    try: return ImageFont.truetype('/System/Library/Fonts/Supplemental/Arial.ttf',size)
    except OSError: return ImageFont.load_default()


def save_gif(path, frames, durations):
    # Each frame is rendered on white; transparent RGB cannot contaminate the preview.
    palette_source=Image.new('RGB',(len(frames)*frames[0].width,frames[0].height),'white')
    for i,frame in enumerate(frames): palette_source.paste(frame,(i*frame.width,0))
    pal=palette_source.quantize(colors=256,method=Image.Quantize.MEDIANCUT)
    encoded=[f.quantize(palette=pal,dither=Image.Dither.FLOYDSTEINBERG) for f in frames]
    encoded[0].save(path,save_all=True,append_images=encoded[1:],duration=durations,loop=0,disposal=1,optimize=True)


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source-dir',type=Path,default=Path(__file__).resolve().parent/'sources')
    parser.add_argument('--output',type=Path,default=Path(__file__).resolve().parents[2]/'Resources/CodexExtraExpressions.png')
    parser.add_argument('--qa-dir',type=Path,default=Path(__file__).resolve().parent/'qa')
    args=parser.parse_args(); args.qa_dir.mkdir(parents=True,exist_ok=True); args.output.parent.mkdir(parents=True,exist_ok=True)
    atlas=Image.new('RGBA',(1536,832)); all_cells=[]; report={'passed':False,'layout':{'columns':8,'rows':4,'cellWidth':192,'cellHeight':208,'validFramesPerRow':6,'footBaselineExclusiveY':202},'thresholdUsedOnlyForDetection':128,'cropPaddingSourcePixels':2,'processing':'Full-sheet connected component extraction, uniform row scale, fixed shoe center and foot baseline. No redraw or color grade. Original source files unchanged. Crop interior RGBA retained before resampling.','rows':[]}
    for row,name in enumerate(NAMES):
        path=args.source_dir/(name+'-source.png'); before=hashlib.sha256(path.read_bytes()).hexdigest()
        crops,details,comps,im=extract(path)
        # A common scale based on median full retained height; never resize each
        # frame to a separate 173px target (that would remove intended breathing).
        median=statistics.median(crop.height for crop,_ in crops)
        scale=NOMINAL_HEIGHT/median
        cells=[]
        for col,((crop,cx),detail) in enumerate(zip(crops,details)):
            resized=crop.resize((round(crop.width*scale),round(crop.height*scale)),Image.Resampling.LANCZOS)
            b=resized.getchannel('A').getbbox()
            resized=resized.crop(b)
            center=cx*scale-b[0]
            x=round(CELL[0]/2-center); y=FOOT-resized.height
            if x<0 or x+resized.width>192 or y<=0: raise ValueError(f'{name}/{col}: subject clips destination')
            cell=Image.new('RGBA',CELL); cell.alpha_composite(resized,(x,y))
            bb=cell.getchannel('A').getbbox()
            if bb[3]!=202: raise ValueError(f'{name}/{col}: wrong foot baseline {bb}')
            atlas.alpha_composite(cell,(col*192,row*208)); cells.append(cell)
            detail.update({'sharedScale':scale,'destinationAlphaBBox':list(bb),'destinationOffset':[x,y],'rgbaSha256':hashlib.sha256(cell.tobytes()).hexdigest()})
        after=hashlib.sha256(path.read_bytes()).hexdigest()
        if before!=after: raise ValueError('Source image was modified')
        report['rows'].append({'name':name,'sourceSha256':before,'sourceAlphaExtrema':list(im.getchannel('A').getextrema()),'sharedScale':scale,'scaleBasisMedianRetainedHeight':median,'targetRegularHeight':173,'durationMs':TIMINGS[name],'majorComponents':len([c for c in comps if c['count']>=30000]),'otherComponentsAboveAlpha128':[{'area':c['count'],'bbox':list(c['bbox'])} for c in comps if c['count']<30000][:30],'frames':details})
        all_cells.append(cells)
        print(name,'prepared',flush=True)
    # Unused cells remain exactly zero RGBA, including RGB under alpha zero.
    for row in range(4):
        for col in [6,7]:
            if any(atlas.crop((col*192,row*208,(col+1)*192,(row+1)*208)).tobytes()): raise ValueError('Unused cell not zero')
    png(args.output,atlas); print('ATLAS_READY',args.output,flush=True)
    contact=Image.new('RGB',(6*224,4*250),'white'); d=ImageDraw.Draw(contact)
    for row,name in enumerate(NAMES):
        for col,cell in enumerate(all_cells[row]):
            x=col*224+16;y=row*250+30
            d.text((x,row*250+6),f'{name} {col+1} ({TIMINGS[name][col]}ms)',fill='#333333',font=font(13))
            d.line((x,y+202,x+192,y+202),fill='#cccccc')
            contact.paste(cell,(x,y),cell)
    contact.save(args.qa_dir/'white-contactsheet.png')
    for row,name in enumerate(NAMES):
        frames=[]
        for i,cell in enumerate(all_cells[row]):
            canvas=Image.new('RGB',(260,264),'white'); draw=ImageDraw.Draw(canvas)
            draw.text((12,10),f'{name}   {sum(TIMINGS[name])/1000:.2f}s loop',fill='#333333',font=font(15))
            canvas.paste(cell,(34,42),cell);frames.append(canvas)
        save_gif(args.qa_dir/(name+'.gif'),frames,TIMINGS[name])
    # Four columns, rendered synchronously on a shared 10ms timeline, for 12s.
    frames=[]; durations=[]; boundaries={0,12000}
    for name in NAMES:
        t=0
        while t<12000:
            for dt in TIMINGS[name]:
                t+=dt
                if t<12000: boundaries.add(t)
    times=sorted(boundaries)
    for t,t2 in zip(times,times[1:]):
        canvas=Image.new('RGB',(4*224,264),'white');draw=ImageDraw.Draw(canvas)
        for row,name in enumerate(NAMES):
            phase=t%sum(TIMINGS[name]);index=0
            for index,dt in enumerate(TIMINGS[name]):
                if phase<dt:break
                phase-=dt
            draw.text((row*224+10,10),name,fill='#333333',font=font(15))
            canvas.paste(all_cells[row][index],(row*224+16,42),all_cells[row][index])
        frames.append(canvas); durations.append(t2-t)
    save_gif(args.qa_dir/'four-expressions.gif',frames,durations)
    report.update({'passed':True,'atlasPath':str(args.output),'atlasSize':list(atlas.size),'atlasSha256':hashlib.sha256(args.output.read_bytes()).hexdigest(),'usedFrames':24,'fullyTransparentUnusedCells':8,'colorSpace':'sRGB PNG chunk, no ICC profile','previewTiming':'Four individual GIFs use exact durationMs. Four-up GIF uses those timelines for 12 seconds; no acceleration.'})
    (args.qa_dir/'extraction-report.json').write_text(json.dumps(report,ensure_ascii=False,indent=2)+'\n')
    print('QA_READY',args.qa_dir,flush=True)

if __name__=='__main__': main()
