#!/usr/bin/env python3
"""
build_all_assets.py — Complete My Business App Store & Website Asset Builder (2026-10-16).

Generates:
1. iPhone App Store Set (1320 x 2868, opaque RGB, 8 slides)
   -> AppStoreAssets/_gemini-2026-10-16/iPhone/
   -> AppStoreAssets/Store-2026-10-16/iPhone/
   -> AppStoreAssets/iPhone/
2. iPhone Duo App Store Set — intentionally mixing Outer Closed (slides 1, 3, 5)
   and Inner Open 2-column (slides 2, 4, 6, 7) + Night Sky / Star White bezels:
   - 2007 x 2853 -> AppStoreAssets/_gemini-2026-10-16/iPhoneDuo/
   - 1398 x 2034 -> AppStoreAssets/_gemini-2026-10-16/iPhoneDuo-1398x2034/
                 -> AppStoreAssets/Store-2026-10-16/iPhoneDuo/
3. iPad Pro 13" App Store Set (2752 x 2064 landscape with LANDSCAPE 3-column iPad, opaque RGB, 8 slides)
   -> AppStoreAssets/_gemini-2026-10-16/iPad/
   -> AppStoreAssets/Store-2026-10-16/iPad/
4. Website /my-business Framed WebP Set (duo-open-calendar-{light,dark}.webp,
   duo-closed-contract-{light,dark}.webp, ipad-*.webp, iphone *.webp)
   -> AppStoreAssets/_gemini-2026-10-16/framed/
"""
import glob, html, json, os, shutil, sys
from PIL import Image, ImageOps

AI_TOOLS = os.path.expanduser('~/Documents/Github/AI-Tools/website-kit')
sys.path.insert(0, AI_TOOLS)
from frame_screenshots import load_frame, compose, web_width  # noqa: E402

REPO_APP = os.path.expanduser('~/Documents/Github/SmallBusinessApp')
REPO_WEB = os.path.expanduser('~/Documents/Github/softwarebygl-website')
GEMINI_DIR = os.path.join(REPO_APP, 'AppStoreAssets/_gemini-2026-10-16')
STORE_DIR = os.path.join(REPO_APP, 'AppStoreAssets/Store-2026-10-16')
CANON_IPHONE_DIR = os.path.join(REPO_APP, 'AppStoreAssets/iPhone')
IPAD_ASSETS = os.path.join(REPO_APP, 'AppStoreAssets/iPadAssets')
WEBKIT_RUNNER = os.path.expanduser('~/Library/Caches/ms-playwright/webkit-2336/pw_run.sh')

FRAMES = {
    'iphone': os.path.join(REPO_WEB, 'scripts/frames/iphone-17-pro-max-portrait.png'),
    'ipad_landscape': os.path.join(REPO_WEB, 'scripts/frames/ipad-pro-13-landscape.png'),
    'duo_outer_dark': os.path.join(AI_TOOLS, 'frames/official-apple-duo/iPhone Duo - Night Sky - Outer Closed Portrait.png'),
    'duo_outer_light': os.path.join(AI_TOOLS, 'frames/official-apple-duo/iPhone Duo - Star White - Outer Closed Portrait.png'),
    'duo_inner_dark': os.path.join(AI_TOOLS, 'frames/official-apple-duo/iPhone Duo - Night Sky - Inner Open Landscape.png'),
    'duo_inner_light': os.path.join(AI_TOOLS, 'frames/official-apple-duo/iPhone Duo - Star White - Inner Open Landscape.png'),
}

IPAD_SLIDES = [
    ('estimate',  'PROPOSALS & ESTIMATES', ['Send proposals', 'that close fast.'], 'Itemized line items, clear totals, and client approvals.'),
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

# Intentional mix of Outer Closed (1, 3, 5) and Inner Open 2-column (2, 4, 6, 7)
# plus Night Sky (dark) and Star White (light) bezels.
DUO_SLIDES = [
    ('01_contacts_home',      'outer_customers_dark.png', 'outer', 'dark',  'CLIENT MANAGEMENT',
     ['Your Entire Client Roster,', 'Organized.'],
     'Seamlessly navigate customers, employees, and subcontractors with instant search.'),
    ('02_contact_detail',     'inner_customers_light.png', 'inner', 'light', 'RELATIONSHIP INTELLIGENCE',
     ['Deep Contact Insight &', 'Full History.'],
     'Complete address history, signed contracts, and one-tap communication.'),
    ('03_contracts_home',     'outer_contracts_dark.png', 'outer', 'dark',  'PROJECT WORKFLOW',
     ['Every Contract at a', 'Single Glance.'],
     'Track signed jobs, completion statuses, and revenue milestones effortlessly.'),
    ('04_contracts_calendar', 'inner_calendar_light.png',  'inner', 'light', 'SCHEDULE & DISPATCH',
     ['Live Calendar Sync,', 'Zero Clashes.'],
     'Visualize multi-day installations and daily crew assignments across your schedule.'),
    ('05_estimate',           'outer_estimate_dark.png',  'outer', 'dark',  'PROPOSALS & ESTIMATES',
     ['Send Proposals That', 'Close Fast.'],
     'Crystal-clear line items, payment terms, and instant client approvals.'),
    ('06_business_details',   'inner_company_light.png',  'inner', 'light', 'ENTERPRISE IDENTITY',
     ['Your Business Profile,', 'Fully Governed.'],
     'Brand licensing, tax identification, and Stripe Connect deposit settings in one place.'),
    ('07_income_expenses',    'inner_stats_dark.png',     'inner', 'dark',  'FINANCIAL MASTERY',
     ['Track Money In & Out,', 'With Precision.'],
     'Real-time profit tracking, expense categorization, and year-over-year analytics.'),
]

BASE_CSS = """
@font-face { font-family: 'InterV'; src: url('Inter.ttf') format('truetype'); font-weight: 100 900; }
@font-face { font-family: 'Italianno'; src: url('Italianno.ttf') format('truetype'); }
html, body { margin: 0; padding: 0; background: #0A0806; }
.slide { position: relative; overflow: hidden; font-family: 'InterV', -apple-system, sans-serif; color: #FBF8F1;
  background:
    radial-gradient(ellipse 60% 45% at 18% 6%, rgba(214,178,94,.30), rgba(214,178,94,0) 70%),
    radial-gradient(ellipse 70% 55% at 92% 108%, rgba(140,104,40,.22), rgba(140,104,40,0) 70%),
    linear-gradient(180deg, #0E0B07 0%, #0A0806 100%); }
.wm { position: absolute; font-family: 'Italianno', cursive; color: rgba(212,175,55,.06); line-height: 1; pointer-events: none; user-select: none; }
.eyebrow { font-weight: 600; text-transform: uppercase; color: #D9BE7C; margin: 0; }
.headline { font-weight: 800; letter-spacing: -0.025em; line-height: 1.04; margin: 0; }
.headline .gold { background: linear-gradient(90deg, #F6E3A4 0%, #D4AF37 100%); -webkit-background-clip: text; background-clip: text; color: transparent; }
.sub { color: #B9AE9B; font-weight: 400; line-height: 1.38; margin: 0; text-wrap: balance; }
.device { position: absolute; display: block; filter: drop-shadow(0 28px 48px rgba(0,0,0,.68)); }
.seal { position: absolute; display: block; }
"""


def esc(s):
    return html.escape(s, quote=True)


def sub_no_orphan(s):
    """Replace the last two spaces with &nbsp; so a 1-word orphan can never wrap onto the last line."""
    words = [esc(w) for w in s.strip().split()]
    if len(words) <= 3:
        return '&nbsp;'.join(words)
    return ' '.join(words[:-2]) + '&nbsp;' + words[-2] + '&nbsp;' + words[-1]


def headline_html(lines, gold_last=True):
    parts = []
    for i, line in enumerate(lines):
        if gold_last and i == len(lines) - 1:
            parts.append(f'<span class="gold">{esc(line)}</span>')
        else:
            parts.append(esc(line))
    return '<br>'.join(parts)


def page_html(layout_css, body):
    return f"""<!doctype html>
<html><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<style>{BASE_CSS}{layout_css}</style></head>
<body><div class="slide">{body}</div></body></html>"""


def phone_html(eyebrow, lines, sub, device_src):
    W, H = 1320 // 2, 2868 // 2
    ratio = 1470 / 3000
    dev_w = 472
    dev_h = dev_w / ratio
    dev_left = (W - dev_w) / 2
    dev_top = H - dev_h + 10
    css = f"""
.slide {{ width: {W}px; height: {H}px; }}
.wm {{ font-size: 960px; left: -140px; top: -180px; }}
.copy {{ position: absolute; left: 56px; top: 146px; width: 540px; }}
.eyebrow {{ font-size: 14px; letter-spacing: .32em; }}
.headline {{ font-size: 48px; margin-top: 22px; }}
.sub {{ font-size: 21px; margin-top: 20px; max-width: 430px; }}
.device {{ width: {dev_w}px; left: {dev_left:.1f}px; top: {dev_top:.1f}px; }}
.seal {{ width: 98px; right: 52px; top: 62px; }}
"""
    return page_html(css, f'''
<div class="wm">GL</div>
<div class="copy">
  <p class="eyebrow">{esc(eyebrow)}</p>
  <h1 class="headline">{headline_html(lines, True)}</h1>
  <p class="sub">{sub_no_orphan(sub)}</p>
</div>
<img class="device" src="{device_src}" alt="">
<img class="seal" src="gl-approved-gold.svg" alt="">
''')


def ipad_landscape_html(eyebrow, lines, sub, device_src):
    W, H = 2752 // 2, 2064 // 2  # 1376 x 1032
    ratio = 3000 / 2300          # landscape iPad bezel
    dev_w = 804
    dev_h = dev_w / ratio        # ~616.4
    dev_left = W - dev_w - 36    # 536
    dev_top = (H - dev_h) / 2    # ~208
    css = f"""
.slide {{ width: {W}px; height: {H}px; }}
.wm {{ font-size: 1100px; left: -160px; bottom: -220px; }}
.copy {{ position: absolute; left: 60px; top: 248px; width: 468px; }}
.eyebrow {{ font-size: 14px; letter-spacing: .32em; }}
.headline {{ font-size: 42px; margin-top: 22px; }}
.sub {{ font-size: 21px; margin-top: 22px; max-width: 420px; }}
.device {{ width: {dev_w:.1f}px; left: {dev_left:.1f}px; top: {dev_top:.1f}px; }}
.seal {{ width: 112px; left: 60px; bottom: 64px; }}
"""
    return page_html(css, f'''
<div class="wm">GL</div>
<div class="copy">
  <p class="eyebrow">{esc(eyebrow)}</p>
  <h1 class="headline">{headline_html(lines, True)}</h1>
  <p class="sub">{sub_no_orphan(sub)}</p>
</div>
<img class="device" src="{device_src}" alt="">
<img class="seal" src="gl-approved-gold.svg" alt="">
''')


def duo_html(eyebrow, lines, sub, device_src, form_factor, canvas_size):
    W, H = canvas_size[0] / 2.0, canvas_size[1] / 2.0
    scale = W / 699.0  # relative to 1398x2034 @2x (699 x 1017)
    if form_factor == 'outer':
        ratio = 1574 / 2194
        dev_h = 620 * scale
        dev_w = dev_h * ratio
        dev_left = (W - dev_w) / 2
        dev_top = H - dev_h - (28 * scale)
    else:
        # Inner Open Landscape (2674 x 2138)
        ratio = 2674 / 2138
        dev_w = 626 * scale
        dev_h = dev_w / ratio
        dev_left = (W - dev_w) / 2
        dev_top = H - dev_h - (85 * scale)

    css = f"""
.slide {{ width: {W}px; height: {H}px; }}
.wm {{ font-size: {880 * scale:.1f}px; left: {-140 * scale:.1f}px; top: {-150 * scale:.1f}px; }}
.copy {{ position: absolute; left: {48 * scale:.1f}px; top: {108 * scale:.1f}px; width: {560 * scale:.1f}px; }}
.eyebrow {{ font-size: {13 * scale:.1f}px; letter-spacing: .3em; }}
.headline {{ font-size: {42 * scale:.1f}px; margin-top: {18 * scale:.1f}px; }}
.sub {{ font-size: {19.5 * scale:.1f}px; margin-top: {18 * scale:.1f}px; max-width: {500 * scale:.1f}px; }}
.device {{ width: {dev_w:.1f}px; left: {dev_left:.1f}px; top: {dev_top:.1f}px; }}
.seal {{ width: {82 * scale:.1f}px; right: {44 * scale:.1f}px; top: {44 * scale:.1f}px; }}
"""
    return page_html(css, f'''
<div class="wm">GL</div>
<div class="copy">
  <p class="eyebrow">{esc(eyebrow)}</p>
  <h1 class="headline">{headline_html(lines, True)}</h1>
  <p class="sub">{sub_no_orphan(sub)}</p>
</div>
<img class="device" src="{device_src}" alt="">
<img class="seal" src="gl-approved-gold.svg" alt="">
''')


def render_batch(jobs):
    """Render a list of (html_path, out_png, target_size_px) grouped by viewport size."""
    from collections import defaultdict
    from playwright.sync_api import sync_playwright

    grouped = defaultdict(list)
    for html_path, out_png, size in jobs:
        if size[0] % 2 == 0 and size[1] % 2 == 0:
            vw, vh, dsf = size[0] // 2, size[1] // 2, 2
        else:
            vw, vh, dsf = (size[0] + 1) // 2, (size[1] + 1) // 2, 2
        grouped[(vw, vh, dsf)].append((html_path, out_png, size))

    with sync_playwright() as p:
        browser = p.webkit.launch(executable_path=WEBKIT_RUNNER)
        for (vw, vh, dsf), group_jobs in grouped.items():
            context = browser.new_context(viewport={'width': vw, 'height': vh}, device_scale_factor=dsf)
            page = context.new_page()
            page.set_default_timeout(5000)
            for html_path, out_png, size in group_jobs:
                page.goto('file://' + html_path, wait_until='load')
                page.wait_for_timeout(180)
                page.screenshot(path=out_png, clip={'x': 0, 'y': 0, 'width': vw, 'height': vh})
                im = Image.open(out_png).convert('RGB')
                if im.size != tuple(size):
                    im = im.resize(tuple(size), Image.LANCZOS)
                im.save(out_png, 'PNG', optimize=True)
                print(f'  Rendered {os.path.basename(out_png)} ({im.size[0]}x{im.size[1]})', flush=True)
            context.close()
        browser.close()


def make_contact_sheet(paths, out_path, cols=4, thumb_w=420):
    imgs = [Image.open(p).convert('RGB') for p in paths]
    if not imgs:
        return
    w0, h0 = imgs[0].size
    thumb_h = round(h0 * thumb_w / w0)
    rows = (len(imgs) + cols - 1) // cols
    pad = 16
    sheet = Image.new('RGB', (cols * thumb_w + (cols + 1) * pad, rows * thumb_h + (rows + 1) * pad), (18, 16, 14))
    for i, im in enumerate(imgs):
        r, c = divmod(i, cols)
        t = im.resize((thumb_w, thumb_h), Image.LANCZOS)
        sheet.paste(t, (pad + c * (thumb_w + pad), pad + r * (thumb_h + pad)))
    sheet.save(out_path, 'PNG')


def main():
    work_dir = os.path.join(GEMINI_DIR, 'work')
    src_dir = os.path.join(GEMINI_DIR, 'source')
    os.makedirs(work_dir, exist_ok=True)

    for sub in ['iphone', 'ipad', 'duo_2007', 'duo_1398']:
        d = os.path.join(work_dir, sub)
        os.makedirs(d, exist_ok=True)
        for asset in ['Inter.ttf', 'Italianno.ttf', 'gl-approved-gold.svg']:
            shutil.copy2(os.path.join(IPAD_ASSETS, asset), os.path.join(d, asset))

    loaded_frames = {k: load_frame(v) for k, v in FRAMES.items()}
    jobs = []

    # 1. iPhone App Store Set (1320 x 2868)
    out_iphone = os.path.join(GEMINI_DIR, 'iPhone')
    os.makedirs(out_iphone, exist_ok=True)
    for idx, (screen, eyebrow, lines, sub) in enumerate(IPHONE_SLIDES, 1):
        shot = os.path.join(src_dir, 'iphone', f'{screen}.png')
        dev_png = os.path.join(work_dir, 'iphone', f'device_{idx:02d}.png')
        compose(shot, loaded_frames['iphone']).save(dev_png, 'PNG')
        html_path = os.path.join(work_dir, 'iphone', f'slide_{idx:02d}.html')
        with open(html_path, 'w', encoding='utf-8') as f:
            f.write(phone_html(eyebrow, lines, sub, f'device_{idx:02d}.png'))
        jobs.append((html_path, os.path.join(out_iphone, f'iphone_{idx:02d}.png'), (1320, 2868)))

    # 2. iPad Pro 13" App Store Set (2752 x 2064 with LANDSCAPE iPad)
    out_ipad = os.path.join(GEMINI_DIR, 'iPad')
    os.makedirs(out_ipad, exist_ok=True)
    for idx, (screen, eyebrow, lines, sub) in enumerate(IPAD_SLIDES, 1):
        shot = os.path.join(src_dir, 'ipad', f'{screen}.png')
        dev_png = os.path.join(work_dir, 'ipad', f'device_{idx:02d}.png')
        compose(shot, loaded_frames['ipad_landscape']).save(dev_png, 'PNG')
        html_path = os.path.join(work_dir, 'ipad', f'slide_{idx:02d}.html')
        with open(html_path, 'w', encoding='utf-8') as f:
            f.write(ipad_landscape_html(eyebrow, lines, sub, f'device_{idx:02d}.png'))
        jobs.append((html_path, os.path.join(out_ipad, f'ipad_{idx:02d}.png'), (2752, 2064)))

    # 3. iPhone Duo App Store Set — BOTH 2007x2853 and 1398x2034
    out_duo_2007 = os.path.join(GEMINI_DIR, 'iPhoneDuo')
    out_duo_1398 = os.path.join(GEMINI_DIR, 'iPhoneDuo-1398x2034')
    os.makedirs(out_duo_2007, exist_ok=True)
    os.makedirs(out_duo_1398, exist_ok=True)
    for idx, (slug, shot_name, form_factor, mode, eyebrow, lines, sub) in enumerate(DUO_SLIDES, 1):
        shot = os.path.join(src_dir, 'duo', shot_name)
        frame_key = f'duo_{form_factor}_{mode}'
        composed = compose(shot, loaded_frames[frame_key])

        for tag, wsub, out_d, size in [
            ('2007', 'duo_2007', out_duo_2007, (2007, 2853)),
            ('1398', 'duo_1398', out_duo_1398, (1398, 2034)),
        ]:
            dev_png = os.path.join(work_dir, wsub, f'device_{idx:02d}.png')
            composed.save(dev_png, 'PNG')
            html_path = os.path.join(work_dir, wsub, f'slide_{idx:02d}.html')
            with open(html_path, 'w', encoding='utf-8') as f:
                f.write(duo_html(eyebrow, lines, sub, f'device_{idx:02d}.png', form_factor, size))
            jobs.append((html_path, os.path.join(out_d, f'duo_{idx:02d}.png'), size))

    print(f'Rendering {len(jobs)} App Store slides via Playwright WebKit...')
    render_batch(jobs)

    # Also save named aliases in iPhoneDuo (01_contacts_home.png .. 07_income_expenses.png)
    for idx, (slug, *_rest) in enumerate(DUO_SLIDES, 1):
        shutil.copy2(os.path.join(out_duo_2007, f'duo_{idx:02d}.png'),
                     os.path.join(out_duo_2007, f'{slug}.png'))

    # Sync to Store-2026-10-16 and canonical AppStoreAssets/iPhone
    os.makedirs(CANON_IPHONE_DIR, exist_ok=True)
    for p in sorted(glob.glob(os.path.join(out_iphone, 'iphone_*.png'))):
        shutil.copy2(p, os.path.join(CANON_IPHONE_DIR, os.path.basename(p)))
        shutil.copy2(p, os.path.join(STORE_DIR, 'iPhone', os.path.basename(p)))
    for p in sorted(glob.glob(os.path.join(out_ipad, 'ipad_*.png'))):
        shutil.copy2(p, os.path.join(STORE_DIR, 'iPad', os.path.basename(p)))
    for p in sorted(glob.glob(os.path.join(out_duo_1398, 'duo_*.png'))):
        shutil.copy2(p, os.path.join(STORE_DIR, 'iPhoneDuo', os.path.basename(p)))

    # 4. Website Framed WebP Set -> AppStoreAssets/_gemini-2026-10-16/framed/
    out_framed = os.path.join(GEMINI_DIR, 'framed')
    os.makedirs(out_framed, exist_ok=True)

    def save_framed_webp(shot_path, frame_key, dest_name, quality=86):
        fr = loaded_frames[frame_key]
        out = compose(shot_path, fr)
        ww = web_width(fr['hole'][2])
        web = out.resize((ww, round(out.height * ww / out.width)), Image.LANCZOS)
        dest = os.path.join(out_framed, dest_name)
        web.save(dest, 'WEBP', quality=quality, method=6)
        return dest

    # Duo website WebPs (Inner Open Landscape 2-column Customers per page.tsx caption/alt, & Outer Closed Portrait Contracts pipeline)
    save_framed_webp(os.path.join(src_dir, 'duo/inner_customers_dark.png'),   'duo_inner_dark',  'duo-open-calendar-dark.webp')
    save_framed_webp(os.path.join(src_dir, 'duo/inner_customers_light.png'),  'duo_inner_light', 'duo-open-calendar-light.webp')
    save_framed_webp(os.path.join(src_dir, 'duo/outer_contracts_dark.png'),   'duo_outer_dark',  'duo-closed-contract-dark.webp')
    save_framed_webp(os.path.join(src_dir, 'duo/outer_contracts_light.png'),  'duo_outer_light', 'duo-closed-contract-light.webp')

    # iPad website WebPs (from our fresh 2752x2064 landscape captures)
    ipad_map = {
        'estimate.png': 'ipad-estimate-dark.webp',
        'estimate_light.png': 'ipad-estimate-light.webp',
        'contract.png': 'ipad-contract-dark.webp',
        'contract_light.png': 'ipad-contract-light.webp',
        'invoice.png': 'ipad-invoice-dark.webp',
        'invoice_light.png': 'ipad-invoice-light.webp',
        'calendar.png': 'ipad-calendar-dark.webp',
        'calendar_light.png': 'ipad-calendar-light.webp',
        'customers.png': 'ipad-customers-dark.webp',
        'customers_light.png': 'ipad-customers-light.webp',
        'employees.png': 'ipad-employees-dark.webp',
        'employees_light.png': 'ipad-employees-light.webp',
        'company.png': 'ipad-company-dark.webp',
        'company_light.png': 'ipad-company-light.webp',
        'stripe.png': 'ipad-get-paid-dark.webp',
        'stripe_light.png': 'ipad-get-paid-light.webp',
        'brand_company_dark.png': 'ipad-brand-company-dark.webp',
        'brand_company_light.png': 'ipad-brand-company-light.webp',
        'brand_customers_dark.png': 'ipad-brand-customers-dark.webp',
        'brand_customers_light.png': 'ipad-brand-customers-light.webp',
    }
    for src_name, webp_name in ipad_map.items():
        sp = os.path.join(src_dir, 'ipad', src_name)
        if os.path.exists(sp):
            save_framed_webp(sp, 'ipad_landscape', webp_name)

    # iPhone website WebPs (all 17 pairs = 34 WebPs referenced across /my-business & subpages)
    iphone_map = {
        '1099.png': '1099-dark.webp',
        '1099_light.png': '1099-light.webp',
        'brand-company.png': 'brand-company-dark.webp',
        'brand-company_light.png': 'brand-company-light.webp',
        'brand-customers.png': 'brand-customers-dark.webp',
        'brand-customers_light.png': 'brand-customers-light.webp',
        'brand-estimate.png': 'brand-estimate-dark.webp',
        'brand-estimate_light.png': 'brand-estimate-light.webp',
        'brand-invoice.png': 'brand-invoice-dark.webp',
        'brand-invoice_light.png': 'brand-invoice-light.webp',
        'brand-receipts.png': 'brand-receipts-dark.webp',
        'brand-receipts_light.png': 'brand-receipts-light.webp',
        'calendar.png': 'calendar-dark.webp',
        'calendar_light.png': 'calendar-light.webp',
        'company.png': 'company-dark.webp',
        'company_light.png': 'company-light.webp',
        'contract.png': 'contract-dark.webp',
        'contract_light.png': 'contract-light.webp',
        'customers.png': 'customers-dark.webp',
        'customers_light.png': 'customers-light.webp',
        'employees.png': 'employees-dark.webp',
        'employees_light.png': 'employees-light.webp',
        'estimate.png': 'estimate-dark.webp',
        'estimate_light.png': 'estimate-light.webp',
        'stripe.png': 'get-paid-dark.webp',
        'stripe_light.png': 'get-paid-light.webp',
        'invoice.png': 'invoice-dark.webp',
        'invoice_light.png': 'invoice-light.webp',
        'receipts.png': 'receipts-dark.webp',
        'receipts_light.png': 'receipts-light.webp',
        'stats.png': 'stats-dark.webp',
        'stats_light.png': 'stats-light.webp',
        'subcontractors.png': 'subcontractors-dark.webp',
        'subcontractors_light.png': 'subcontractors-light.webp',
    }
    for src_name, webp_name in iphone_map.items():
        sp = os.path.join(src_dir, 'iphone', src_name)
        if os.path.exists(sp):
            save_framed_webp(sp, 'iphone', webp_name)

    # Build contact sheets for visual inspection
    make_contact_sheet(sorted(glob.glob(os.path.join(out_iphone, 'iphone_*.png'))),
                       os.path.join(work_dir, 'sheet_iphone.png'), cols=4, thumb_w=360)
    make_contact_sheet(sorted(glob.glob(os.path.join(out_ipad, 'ipad_*.png'))),
                       os.path.join(work_dir, 'sheet_ipad.png'), cols=4, thumb_w=520)
    make_contact_sheet(sorted(glob.glob(os.path.join(out_duo_2007, 'duo_*.png'))),
                       os.path.join(work_dir, 'sheet_duo_2007x2853.png'), cols=4, thumb_w=380)
    make_contact_sheet(sorted(glob.glob(os.path.join(out_duo_1398, 'duo_*.png'))),
                       os.path.join(work_dir, 'sheet_duo_1398x2034.png'), cols=4, thumb_w=380)
    # Build Duo WebP contact sheet (top row: inner open dark/light, bottom row: outer closed dark/light)
    duo_webp_sheet = Image.new('RGB', (1680, 1280), (18, 16, 14))
    for i, nm in enumerate(['duo-open-calendar-dark.webp', 'duo-open-calendar-light.webp']):
        im = Image.open(os.path.join(out_framed, nm)).convert('RGBA')
        t = im.resize((780, round(im.height * 780 / im.width)), Image.LANCZOS)
        duo_webp_sheet.paste(t, (40 + i * 820, 30), t)
    for i, nm in enumerate(['duo-closed-contract-dark.webp', 'duo-closed-contract-light.webp']):
        im = Image.open(os.path.join(out_framed, nm)).convert('RGBA')
        t = im.resize((420, round(im.height * 420 / im.width)), Image.LANCZOS)
        duo_webp_sheet.paste(t, (220 + i * 820, 640), t)
    duo_webp_sheet.save(os.path.join(work_dir, 'sheet_duo_webp.png'), 'PNG')

    # Also update Store-2026-10-16 contact sheets and source captures so nothing stale remains there
    store_work = os.path.join(STORE_DIR, 'tools/work')
    os.makedirs(store_work, exist_ok=True)
    shutil.copy2(os.path.join(work_dir, 'sheet_iphone.png'), os.path.join(store_work, 'sheet_out_iphone.png'))
    shutil.copy2(os.path.join(work_dir, 'sheet_ipad.png'), os.path.join(store_work, 'sheet_out_ipad.png'))
    shutil.copy2(os.path.join(work_dir, 'sheet_duo_1398x2034.png'), os.path.join(store_work, 'sheet_out_duo.png'))
    for sub in ['iphone', 'ipad', 'duo']:
        os.makedirs(os.path.join(STORE_DIR, 'source', sub), exist_ok=True)
        for p in glob.glob(os.path.join(src_dir, sub, '*.png')):
            shutil.copy2(p, os.path.join(STORE_DIR, 'source', sub, os.path.basename(p)))
    dup_store = os.path.join(STORE_DIR, 'source/duo/inner_company_dark.png')
    if os.path.exists(dup_store):
        os.remove(dup_store)

    print('All App Store sets, Website framed WebPs, and contact sheets built successfully!')


if __name__ == '__main__':
    main()
