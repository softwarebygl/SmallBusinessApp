#!/usr/bin/env python3
import os
import shutil
import sys
from PIL import Image

sys.path.append('/Users/adriangutierrez/Documents/Github/AI-Tools/website-kit')
from frame_screenshots import load_frame, compose, web_width

ASSETS_DIR = '/Users/adriangutierrez/Documents/Github/SmallBusinessApp/AppStoreAssets/iPadAssets'
SCREENSHOTS_DIR = '/Users/adriangutierrez/Documents/Github/softwarebygl-website/public/screenshots'
FRAME_PATH = '/Users/adriangutierrez/Documents/Github/AI-Tools/website-kit/frames/ipad-pro-13-landscape.png'
BRAND_DIR = '/Users/adriangutierrez/Documents/Github/AI-Tools/website-kit/appstore/brand-assets'

os.makedirs(ASSETS_DIR, exist_ok=True)

# Copy brand assets
for f in ['Inter.ttf', 'Italianno.ttf', 'gl-approved-gold.svg']:
    src = os.path.join(BRAND_DIR, f)
    dst = os.path.join(ASSETS_DIR, f)
    shutil.copy2(src, dst)
    print(f'Copied {f} to {ASSETS_DIR}')

# Screen mapping: screen_id -> authentic screenshot filename
SCREENS = {
    'estimate': 'ipad-estimate-dark.png',
    'contract': 'ipad-contract-dark.png',
    'invoice': 'ipad-invoice-dark.png',
    'calendar': 'ipad-calendar-dark.png',
    'customers': 'ipad-customers-dark.png',
    'employees': 'ipad-employees-dark.png',
    'brand_company': 'ipad-brand-company-dark.png',
    'get_paid': 'ipad-get-paid-dark.png',
}

fr = load_frame(FRAME_PATH)
print(f"Loaded frame {FRAME_PATH}, hole: {fr['hole']}")

for screen_id, shot_filename in SCREENS.items():
    shot_path = os.path.join(SCREENSHOTS_DIR, shot_filename)
    if not os.path.exists(shot_path):
        raise FileNotFoundError(f"Missing authentic screenshot: {shot_path}")
    
    framed = compose(shot_path, fr)
    ww = web_width(fr['hole'][2])  # 1600
    # Use 2000px width for extra crispness on 2752x2064 canvas
    target_w = 2000
    target_h = round(framed.height * target_w / framed.width)
    resized = framed.resize((target_w, target_h), Image.Resampling.LANCZOS)
    
    out_name = f"dev-{screen_id}-ipad.webp"
    out_path = os.path.join(ASSETS_DIR, out_name)
    resized.save(out_path, "WEBP", quality=90, method=6)
    print(f"Saved {out_name} ({target_w}x{target_h})")

print("All iPad framed device assets generated successfully.")
