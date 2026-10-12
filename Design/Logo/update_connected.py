"""Regenerate the connected vector wordmark and its self-contained preview."""
from pathlib import Path
import json
import math
import re
import xml.etree.ElementTree as ET

root = Path(__file__).resolve().parent
colors = {'master': '#d5ed79', 'film': '#efaa71', 'sstv': '#8ddcdb', 'tv': '#ead477', 'radio': '#b8a1f2'}
# Only two ligatures: the first A grows into N; L shares its foot with I.
# Joins are part of the outlines and use the same 18-unit stroke as the letters.
base_a = 'M0 80 23 0H47L70 80H50L46 62H23L19 80ZM27 46H42L35 18Z'
joined_a = 'M0 80 23 0H47L65 62H99V80H50L46 62H23L19 80ZM27 46H42L35 18Z'
base_n = 'M0 80V0H20L48 48V0H66V80H46L18 32V80Z'
base_e = 'M0 0H60V17H20V31H54V48H20V63H60V80H0Z'
signals = {'master': 'M0 35H49V46H0Z', 'film': 'M0 24H49V31H0ZM0 37H49V44H0ZM0 50H49V57H0Z', 'sstv': 'M0 37H10V25H20V49H30V32H40V37H49V45H34V57H24V33H18V45H0Z'}
signals['tv'] = 'M0 37H7V16H14V37H23V22H30V37H39V28H46V37H49V44H46V53H39V44H30V59H23V44H14V65H7V44H0Z'
# Two broad folds, with the wordmark's slant counteracted about the symbol center.
# Compensate the actual outline so both SVG and native path exports agree.
radio_points = [(0, 35), (1, 35), (10, 16), (21, 44), (32, 16), (47, 35),
                (49, 35), (49, 45), (41, 45), (32, 34), (21, 64), (10, 34),
                (7, 45), (0, 45)]
signals['radio'] = 'M' + 'L'.join(
    f'{x + math.tan(math.radians(13)) * (y - 40):.4f} {y}' for x, y in radio_points) + 'Z'
def make_svg(mode):
    a, first_a, n, e = base_a, joined_a, base_n, base_e
    l = 'M0 0H20V62H91V80H0Z'
    i = 'M0 0H20V80H0Z'
    if mode == 'film':
        a = 'M0 80 21 8Q23 0 31 0H39Q47 0 49 8L70 80H50L46 62H23L19 80ZM27 46H42L35 18Z'
        first_a = 'M0 80 21 8Q23 0 31 0H39Q47 0 49 8L61 50Q64 62 76 62H99V80H58Q50 80 48 72L46 62H23L19 80ZM27 46H42L35 18Z'
        n = 'M0 80V0H14Q20 0 24 7L48 48V0H66V80H52Q46 80 42 73L18 32V80Z'
        e = 'M10 0H60V17H24Q20 17 20 21V31H54V48H20V59Q20 63 24 63H60V80H10Q0 80 0 70V10Q0 0 10 0Z'
        # Two sprocket holes in L; its foot curls into the existing L–I ligature.
        l = 'M0 0H20V50Q20 62 32 62H91V80H28Q0 80 0 52ZM6 12V22H14V12ZM6 32V42H14V32Z'
    elif mode == 'sstv':
        # A small stepped interruption is built into each N diagonal.
        n = 'M0 80V0H20L35 26H41V36L48 48V0H66V80H46L31 54H25V44L18 32V80Z'
        e = 'M0 0H60V17H20V30H49L57 38V48H20V63H60V80H0Z'
    elif mode == 'tv':
        # A horizontal blanking gap and a shifted lower field suggest loss of line sync.
        counter = 'M27 46Q35 48 42 46L39 30Q35 21 31 30Z'
        a = base_a.split('ZM')[0] + 'Z' + counter
        first_a = joined_a.split('ZM')[0] + 'Z' + counter
        n = 'M0 34V0H20L40 34H19L18 32V34ZM48 0H66V34H48ZM3 42H21V80H3ZM27 42H47L51 48V42H69V80H49Z'
        e = 'M0 0H52Q60 0 60 8V17H20V31H64V48H20V63H60V72Q60 80 52 80H0Z'
    elif mode == 'radio':
        # A single clipped shoulder adds character without busy I/E modifications.
        n = 'M0 80V0H12L20 8L48 48V0H66V80H46L18 32V80Z'
    groups = [
        [(25, first_a), (104, n)],
        [(179, a)],
        [(323, l), (394, i)],
        [(423, n)],
        [(498, e)],
    ]
    letters = ''.join('<g class="letter-motion">' + ''.join(f'<path transform="translate({x} 0)" fill-rule="evenodd" d="{d}"/>' for x,d in group) + '</g>' for group in groups)
    signal_rule = ' fill-rule="evenodd"' if mode == 'tv' else ''
    return f'''<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 605 132" role="img" aria-label="Ana-Line · {mode} · ligature wordmark"><title>Ana-Line — 粗笔画连字</title><g fill="currentColor" transform="translate(27 24) skewX(-13)">{letters}<g class="connections"/><g class="signal-motion"><path transform="translate(258 0)" fill="{colors[mode]}"{signal_rule} d="{signals[mode]}"/></g></g></svg>'''
marks = {mode: make_svg(mode) for mode in colors}
for mode, svg in marks.items():
    ET.fromstring(svg)
    (root / f'ana-line-{mode}.svg').write_text(svg)
for mode in ('film', 'tv', 'radio'):
    preview = marks[mode].replace('<g fill="currentColor"',
        '<rect width="605" height="132" fill="#171a18"/><g color="#f1eee4" fill="currentColor"', 1)
    (root / f'ana-line-{mode}-preview.svg').write_text(preview)
p = root / 'preview.html'
s = p.read_text()
if 'data-mode="tv"' not in s:
    s = s.replace('>SSTV</button>', '>SSTV</button><button data-mode="tv" aria-pressed="false">地面模拟无线电视</button>')
if 'data-mode="radio"' not in s:
    s = s.replace('>地面模拟无线电视</button>', '>地面模拟无线电视</button><button data-mode="radio" aria-pressed="false">RADIO · AM / FM</button>')
s = re.sub(r'const marks=.*?;\nconst config=', 'const marks=' + json.dumps(marks, ensure_ascii=False) + ';\nconst config=', s, flags=re.S)
s = re.sub(r'<span>(?:CONCEPT|CONNECTED|LIGATURE).*?</span></header>', '<span>LIGATURE · C</span></header>', s)
s = re.sub(r'<h1>.*?</h1>', '<h1>两处连笔，笔画同重。</h1>', s)
config = {
    'master': [colors['master'], 'ANALOG IMAGE INSTRUMENTS', 'AL / SYSTEM', '只保留 A—N、L—I 两处连笔，直接延展字母的主笔画。18 单位粗度与字干一致；其余字距留白，中间短横恢复简单形态。'],
    'film': [colors['film'], 'FILM DAMAGE / EXPOSURE', 'AL / FILM', 'L 的竖笔嵌入两个胶片片孔，底部像胶片卷带一样弯入 I，形成原有的粗连笔。保留 A 的圆肩与 E 的柔和内角，让胶片特征直接进入字母。'],
    'sstv': [colors['sstv'], 'SLOW SCAN TELEVISION', 'AL / TX—RX', '两个 N 的斜笔加入短促的阶梯转折，E 的中横切出斜角；保留粗笔画的整体重量，呈现扫描信号的节奏。'],
    'tv': [colors['tv'], 'TERRESTRIAL ANALOG TELEVISION', 'AL / AIR', '两个 N 像电视画面失去行同步一样横向断开，下半部分向右偏移；E 的中横向右探出，呼应错行与重影。保留 A 的 CRT 弧面内孔，以及中间的八木天线。'],
    'radio': [colors['radio'], 'BROADCAST RADIO / AM · FM', 'AL / RADIO', '中间波形摆正并加粗，只保留两次宽折返，使视觉重量接近其他模式。I 和 E 恢复完整笔画，N 仅保留一处肩部切角；两处粗连笔与电子紫 #B8A1F2 保持一致。'],
}
s = re.sub(r'const config=.*?;let activeMode=', 'const config=' + json.dumps(config, ensure_ascii=False) + ';let activeMode=', s, flags=re.S)
start = s.index("let activeMode='master'")
end = s.index('function select(', start)
s = s[:start] + '''let activeMode='master';
let running=[];
function animateLogo(mode){
  running.forEach(a=>a.cancel());running=[];
  if(matchMedia('(prefers-reduced-motion: reduce)').matches)return;
  const svg=document.querySelector('#logo svg');
  svg.querySelectorAll('.letter-motion').forEach((wrapper,i)=>{
    // Animate the unpositioned wrapper: preserve each glyph's SVG transform.
    running.push(wrapper.animate([
      {transform:'translate(-7px, 2px)',opacity:.55},
      {transform:'translate(0, 0)',opacity:1}
    ],{duration:mode==='film'?520:380,delay:i*25,easing:'cubic-bezier(.2,.75,.25,1)',fill:'backwards'}));
  });
  // Opacity leaves the signal's attachment points and scale intact.
  ['.connections','.signal-motion'].forEach((selector,i)=>{
    running.push(svg.querySelector(selector).animate(
      [{opacity:.15},{opacity:1}],
      {duration:400,delay:120+i*50,easing:'ease-out',fill:'backwards'}));
  });
}
''' + s[end:]
s = s.replace('CUSTOM VECTOR LETTERING / FORWARD SLANT 13°', 'LIGATURE LETTERING / 18 UNIT JOINS / 13° SLANT')
p.write_text(s)
print('Updated logo variants and preview.html')
