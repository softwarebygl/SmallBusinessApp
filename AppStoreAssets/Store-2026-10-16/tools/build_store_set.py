#!/usr/bin/env python3
"""
build_store_set.py — My Business App Store set, 2026-10-16.

Real simulator captures -> Apple bezel (pixel-exact) -> HTML/CSS layout -> Playwright WebKit @2x
-> exact App Store pixel size, opaque RGB PNG.

Inputs:  --captures DIR   (folder with iphone/, ipad/, duo/ subfolders of raw simctl PNGs)
         --out DIR        (output root; writes iPhone/, iPad/, iPhoneDuo/ and source/)
"""
import argparse, glob, html, json, os, shutil, sys
from PIL import Image

AI_TOOLS = os.path.expanduser('~/Documents/Github/AI-Tools/website-kit')
sys.path.insert(0, AI_TOOLS)
from frame_screenshots import load_frame, compose  # noqa: E402

REPO_WEB = os.path.expanduser('~/Documents/Github/softwarebygl-website')
FRAMES = {
    'iphone': os.path.join(REPO_WEB, 'scripts/frames/iphone-17-pro-max-portrait.png'),
    'ipad': os.path.join(REPO_WEB, 'scripts/frames/ipad-pro-13-portrait.png'),
    'duo_dark': os.path.join(AI_TOOLS, 'frames/official-apple-duo/iPhone Duo - Night Sky - Outer Closed Portrait.png'),
    'duo_light': os.path.join(AI_TOOLS, 'frames/official-apple-duo/iPhone Duo - Star White - Outer Closed Portrait.png'),
}
IPAD_ASSETS = os.path.expanduser('~/Documents/Github/SmallBusinessApp/AppStoreAssets/iPadAssets')
WEBKIT_RUNNER = os.path.expanduser('~/Library/Caches/ms-playwright/webkit-2336/pw_run.sh')
FONT_INTER = os.path.join(IPAD_ASSETS, 'Inter.ttf')
FONT_ITALIANNO = os.path.join(IPAD_ASSETS, 'Italianno.ttf')
SEAL = os.path.join(IPAD_ASSETS, 'gl-approved-gold.svg')

# Copy is carried over verbatim from the existing sets (AppStoreAssets/iPadAssets/_p_ipad_0N.html
# and Scripts/render_appstore_duo_cards.py). Flags are reported separately, not edited here.
IPAD_SLIDES = [
    ('estimate',  'PROPOSALS & ESTIMATES', ['Send', 'proposals that', 'close fast.'], 'Itemized line items, clear totals, and client approvals.'),
    ('contract',  'PROJECT WORKFLOW', ['Signed contracts,', 'legally sealed.'], 'Capture legally binding physical signatures on device.'),
    ('invoice',   'INVOICES & BILLING', ['Milestone billing,', 'paid on time.'], 'Transform estimates into professional invoices in one tap.'),
    ('calendar',  'SCHEDULE & DISPATCH', ['Live calendar sync,', 'zero clashes.'], 'Visualize multi-day crew assignments and job schedules.'),
    ('customers', 'CLIENT MANAGEMENT', ['Your client roster,', 'fully organized.'], 'Complete job history, service addresses, and instant contact.'),
    ('employees', 'CREW MANAGEMENT', ['Track crew hours &', 'run payroll.'], 'Hourly wage tracking and automated payday calculations.'),
    ('company',   'ENTERPRISE IDENTITY', ['Your business profile,', 'fully governed.'], 'Custom branding, contractor licensing, and credentials.'),
    ('stripe',    'PAYMENTS & DEPOSITS', ['Accept card payments,', 'straight to bank.'], 'Stripe Connect deposits with automated bookkeeping.'),
]
IPHONE_SLIDES = [
    ('estimate',  IPAD_SLIDES[0][1], IPAD_SLIDES[0][2], IPAD_SLIDES[0][3]),
    ('contract',  IPAD_SLIDES[1][1], IPAD_SLIDES[1][2], IPAD_SLIDES[1][3]),
    ('invoice',   IPAD_SLIDES[2][1], IPAD_SLIDES[2][2], IPAD_SLIDES[2][3]),
    ('calendar',  IPAD_SLIDES[3][1], IPAD_SLIDES[3][2], IPAD_SLIDES[3][3]),
    ('customer',  IPAD_SLIDES[4][1], IPAD_SLIDES[4][2], IPAD_SLIDES[4][3]),
    ('employees', IPAD_SLIDES[5][1], IPAD_SLIDES[5][2], IPAD_SLIDES[5][3]),
    ('company',   IPAD_SLIDES[6][1], IPAD_SLIDES[6][2], IPAD_SLIDES[6][3]),
    ('stripe',    IPAD_SLIDES[7][1], IPAD_SLIDES[7][2], IPAD_SLIDES[7][3]),
]
# Duo: outer closed display (1398 x 2034). Bezel colour alternates on purpose:
# Night Sky for dark captures, Star White for light captures.
DUO_SLIDES = [
    ('customers', 'dark',  'CLIENT MANAGEMENT', ['Your Entire Client Roster,', 'Organized.'], 'Seamlessly navigate customers, employees, and subcontractors with instant search.'),
    ('customer',  'light', 'RELATIONSHIP INTELLIGENCE', ['Deep Contact Insight &', 'Full History.'], 'Complete address history, signed contracts, and one-tap communication.'),
    ('contracts', 'dark',  'PROJECT WORKFLOW', ['Every Contract at a', 'Single Glance.'], 'Track signed jobs, completion statuses, and revenue milestones effortlessly.'),
    ('calendar',  'light', 'SCHEDULE & DISPATCH', ['Live Calendar Sync,', 'Zero Clashes.'], 'Visualize multi-day installations and daily crew assignments across your schedule.'),
    ('estimate',  'dark',  'PROPOSALS & ESTIMATES', ['Send Proposals That', 'Close Fast.'], 'Crystal-clear line items, payment terms, and instant client approvals.'),
    ('company',   'light', 'ENTERPRISE IDENTITY', ['Your Business Profile,', 'Fully Governed.'], 'Brand licensing, tax identification, and Stripe Connect deposit settings in one place.'),
    ('stats',     'dark',  'FINANCIAL MASTERY', ['Track Money In & Out,', 'With Precision.'], 'Real-time profit tracking, expense categorization, and year-over-year analytics.'),
]

# Canvas sizes in App Store pixels; CSS px = pixels / 2 (rendered at deviceScaleFactor 2).
SIZES = {
    'iphone': (1320, 2868),
    'ipad': (2752, 2064),   # landscape canvas; the iPad capture is portrait (see README)
    'duo': (1398, 2034),
}

BASE_CSS = """
@font-face { font-family: 'InterV'; src: url('Inter.ttf') format('truetype'); font-weight: 100 900; }
@font-face { font-family: 'Italianno'; src: url('Italianno.ttf') format('truetype'); }
html, body { margin: 0; padding: 0; background: #0A0806; }
.slide { position: relative; overflow: hidden; font-family: 'InterV', -apple-system, sans-serif; color: #FBF8F1;
  background:
    radial-gradient(ellipse 60% 45% at 18% 6%, rgba(214,178,94,.30), rgba(214,178,94,0) 70%),
    radial-gradient(ellipse 70% 55% at 92% 108%, rgba(140,104,40,.22), rgba(140,104,40,0) 70%),
    linear-gradient(180deg, #0E0B07 0%, #0A0806 100%); }
.wm { position: absolute; font-family: 'Italianno', cursive; color: rgba(212,175,55,.075); line-height: 1; pointer-events: none; user-select: none; }
.eyebrow { font-weight: 600; text-transform: uppercase; color: #D9BE7C; margin: 0; }
.headline { font-weight: 800; letter-spacing: -0.025em; line-height: 1.02; margin: 0; }
.headline .gold { background: linear-gradient(90deg, #F6E3A4 0%, #D4AF37 100%); -webkit-background-clip: text; background-clip: text; color: transparent; }
.sub { color: #B9AE9B; font-weight: 400; line-height: 1.35; margin: 0; text-wrap: balance; }
.device { position: absolute; display: block; filter: drop-shadow(0 28px 48px rgba(0,0,0,.65)); }
.seal { position: absolute; display: block; }
"""


def esc(s):
    return html.escape(s, quote=True)


def headline_html(lines, gold_last):
    parts = []
    for i, line in enumerate(lines):
        if gold_last and i == len(lines) - 1:
            parts.append(f'<span class="gold">{esc(line)}</span>')
        else:
            parts.append(esc(line))
    return '<br>'.join(parts)


def phone_html(eyebrow, lines, sub, device_src):
    W, H = SIZES['iphone'][0] // 2, SIZES['iphone'][1] // 2
    ratio = 1470 / 3000
    dev_w = 470
    dev_h = dev_w / ratio
    dev_left = (W - dev_w) / 2
    dev_top = H - dev_h
    css = f"""
.slide {{ width: {W}px; height: {H}px; }}
.wm {{ font-size: 1000px; left: -120px; bottom: -220px; }}
.copy {{ position: absolute; left: 58px; top: 150px; width: 560px; }}
.eyebrow {{ font-size: 15px; letter-spacing: .34em; }}
.headline {{ font-size: 50px; margin-top: 26px; }}
.sub {{ font-size: 23px; margin-top: 22px; max-width: 520px; }}
.device {{ width: {dev_w}px; left: {dev_left}px; top: {dev_top:.1f}px; }}
.seal {{ width: 104px; right: 56px; top: 64px; }}
"""
    return page_html(css, f'''
<div class="wm">GL</div>
<div class="copy">
  <p class="eyebrow">{esc(eyebrow)}</p>
  <h1 class="headline">{headline_html(lines, True)}</h1>
  <p class="sub">{esc(sub)}</p>
</div>
<img class="device" src="{device_src}" alt="">
<img class="seal" src="gl-approved-gold.svg" alt="">
''')


def ipad_html(eyebrow, lines, sub, device_src):
    W, H = SIZES['ipad'][0] // 2, SIZES['ipad'][1] // 2
    ratio = 2300 / 3000
    dev_h = 740
    dev_w = dev_h * ratio
    dev_left = W - dev_w - 56
    dev_top = (H - dev_h) / 2
    css = f"""
.slide {{ width: {W}px; height: {H}px; }}
.wm {{ font-size: 1250px; right: -160px; top: -300px; }}
.copy {{ position: absolute; left: 96px; top: 250px; width: 650px; }}
.eyebrow {{ font-size: 16px; letter-spacing: .34em; }}
.headline {{ font-size: 52px; margin-top: 30px; }}
.sub {{ font-size: 25px; margin-top: 28px; max-width: 600px; }}
.device {{ width: {dev_w:.1f}px; left: {dev_left:.1f}px; top: {dev_top:.1f}px; }}
.seal {{ width: 124px; left: 96px; bottom: 60px; }}
"""
    return page_html(css, f'''
<div class="wm">GL</div>
<div class="copy">
  <p class="eyebrow">{esc(eyebrow)}</p>
  <h1 class="headline">{headline_html(lines, True)}</h1>
  <p class="sub">{esc(sub)}</p>
</div>
<img class="device" src="{device_src}" alt="">
<img class="seal" src="gl-approved-gold.svg" alt="">
''')


def duo_html(eyebrow, lines, sub, device_src):
    W, H = SIZES['duo'][0] // 2, SIZES['duo'][1] // 2
    ratio = 1574 / 2194
    dev_h = 640
    dev_w = dev_h * ratio
    dev_left = (W - dev_w) / 2
    dev_top = 372
    css = f"""
.slide {{ width: {W}px; height: {H}px; }}
.wm {{ font-size: 900px; left: -150px; top: 330px; }}
.copy {{ position: absolute; left: 48px; top: 120px; width: 600px; }}
.eyebrow {{ font-size: 13px; letter-spacing: .3em; }}
.headline {{ font-size: 44px; margin-top: 18px; }}
.sub {{ font-size: 20px; margin-top: 18px; max-width: 600px; }}
.device {{ width: {dev_w:.1f}px; left: {dev_left:.1f}px; top: {dev_top}px; }}
.seal {{ width: 76px; right: 46px; top: 44px; }}
"""
    return page_html(css, f'''
<div class="wm">GL</div>
<div class="copy">
  <p class="eyebrow">{esc(eyebrow)}</p>
  <h1 class="headline">{headline_html(lines, True)}</h1>
  <p class="sub">{esc(sub)}</p>
</div>
<img class="device" src="{device_src}" alt="">
<img class="seal" src="gl-approved-gold.svg" alt="">
''')


def page_html(layout_css, body):
    return f"""<!doctype html>
<html><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<style>{BASE_CSS}{layout_css}</style></head>
<body><div class="slide">{body}</div></body></html>"""


def prepare_frame(shot_path, frame_path, out_path):
    fr = load_frame(frame_path)
    shot = Image.open(shot_path).convert('RGB')
    if shot.size != fr['hole'][2:]:
        raise SystemExit(f'capture {shot_path} is {shot.size}, frame hole is {fr["hole"][2:]}')
    composed = compose(shot_path, fr)  # RGBA: screen inside bezel, transparent outside
    composed.save(out_path, 'PNG')
    return out_path


def render(html_path, out_png, size):
    from playwright.sync_api import sync_playwright
    W, H = size[0] // 2, size[1] // 2
    with sync_playwright() as p:
        browser = p.webkit.launch(executable_path=WEBKIT_RUNNER)
        page = browser.new_page(viewport={'width': W, 'height': H}, device_scale_factor=2)
        page.goto('file://' + html_path)
        page.evaluate('document.fonts.ready.then(() => true)')
        page.wait_for_timeout(300)
        page.screenshot(path=out_png, clip={'x': 0, 'y': 0, 'width': W, 'height': H})
        browser.close()
    im = Image.open(out_png).convert('RGB')
    if im.size != tuple(size):
        im = im.resize(tuple(size), Image.LANCZOS)
    im.save(out_png, 'PNG', optimize=True)
    return im.size


def build_group(group, slides, work, out_dir, captures, frames):
    os.makedirs(work, exist_ok=True)
    for name in ['Inter.ttf', 'Italianno.ttf']:
        shutil.copy(os.path.join(IPAD_ASSETS, name), work)
    shutil.copy(SEAL, os.path.join(work, 'gl-approved-gold.svg'))
    os.makedirs(out_dir, exist_ok=True)
    manifest = []
    for idx, slide in enumerate(slides, 1):
        if group == 'duo':
            screen, mode, eyebrow, lines, sub = slide
            shot = captures[screen]
            frame = FRAMES['duo_dark' if mode == 'dark' else 'duo_light']
            out_name = f'duo_{idx:02d}.png'
            layout = duo_html
        else:
            screen, eyebrow, lines, sub = slide
            shot = captures[screen]
            frame = FRAMES[group]
            mode = 'dark'
            out_name = f'{group}_{idx:02d}.png'
            layout = ipad_html if group == 'ipad' else phone_html
        dev_png = os.path.join(work, f'device_{idx:02d}.png')
        prepare_frame(shot, frame, dev_png)
        html_path = os.path.join(work, f'slide_{idx:02d}.html')
        with open(html_path, 'w', encoding='utf-8') as f:
            f.write(layout(eyebrow, lines, sub, os.path.basename(dev_png)))
        target = os.path.join(out_dir, out_name)
        size = render(html_path, target, SIZES[group if group != 'duo' else 'duo'])
        manifest.append({'file': out_name, 'screen': screen, 'appearance': mode,
                         'eyebrow': eyebrow, 'headline': ' '.join(lines), 'sub': sub, 'size': list(size)})
        print(group, out_name, size, flush=True)
    return manifest


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--captures', required=True)
    ap.add_argument('--out', required=True)
    ap.add_argument('--work', required=True)
    ap.add_argument('--only', default='iphone,ipad,duo')
    a = ap.parse_args()
    a.captures, a.out, a.work = (os.path.abspath(a.captures), os.path.abspath(a.out), os.path.abspath(a.work))
    only = a.only.split(',')
    cap = lambda sub: {os.path.splitext(os.path.basename(p))[0].split('_', 1)[-1]: p
                       for p in glob.glob(os.path.join(a.captures, sub, '*.png'))}
    result = {}
    if 'iphone' in only:
        c = {k: v for k, v in cap('iphone').items()}
        result['iphone'] = build_group('iphone', IPHONE_SLIDES, os.path.join(a.work, 'iphone'),
                                       os.path.join(a.out, 'iPhone'), c, FRAMES)
    if 'ipad' in only:
        c = cap('ipad')
        result['ipad'] = build_group('ipad', IPAD_SLIDES, os.path.join(a.work, 'ipad'),
                                     os.path.join(a.out, 'iPad'), c, FRAMES)
    if 'duo' in only:
        c = cap('duo')
        result['duo'] = build_group('duo', DUO_SLIDES, os.path.join(a.work, 'duo'),
                                    os.path.join(a.out, 'iPhoneDuo'), c, FRAMES)
    with open(os.path.join(a.work, 'manifest.json'), 'w', encoding='utf-8') as f:
        json.dump(result, f, indent=2, ensure_ascii=False)
    print('done')


if __name__ == '__main__':
    main()
