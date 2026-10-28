#!/usr/bin/env python3
import os
import sys
sys.path.append('/Users/adriangutierrez/Documents/Github/AI-Tools/website-kit')
from frame_screenshots import load_frame, compose
from PIL import Image, ImageDraw, ImageFont, ImageFilter

out_dir = '/Users/adriangutierrez/Documents/Github/SmallBusinessApp/AppStoreAssets/iPhoneDuo'
os.makedirs(out_dir, exist_ok=True)
W, H = 2007, 2853

font_inter_path = '/Users/adriangutierrez/Documents/Github/AI-Tools/website-kit/appstore/brand-assets/Inter.ttf'
font_it_path = '/Users/adriangutierrez/Documents/Github/AI-Tools/website-kit/appstore/brand-assets/Italianno.ttf'

font_eyebrow = ImageFont.truetype(font_inter_path, 34)
font_headline = ImageFont.truetype(font_inter_path, 98)
font_sub = ImageFont.truetype(font_inter_path, 42)
font_wm = ImageFont.truetype(font_it_path, 1500)

outer_frame_path = '/Users/adriangutierrez/Documents/Github/AI-Tools/website-kit/frames/official-apple-duo/iPhone Duo - Star White - Outer Closed Portrait.png'
inner_frame_path = '/Users/adriangutierrez/Documents/Github/AI-Tools/website-kit/frames/official-apple-duo/iPhone Duo - Star White - Inner Open Landscape.png'

frame_data_outer = load_frame(outer_frame_path)
frame_data_inner = load_frame(inner_frame_path)

def prepare_outer_shot(input_path, output_path):
    im = Image.open(input_path).convert('RGBA')
    bg_color = (10, 8, 6, 255)
    
    # 1. Right rail
    rail_w = 230
    rail_crop = im.crop((im.width - rail_w, 0, im.width, im.height))
    draw_rect = Image.new('RGBA', (rail_w, im.height), bg_color)
    im.paste(draw_rect, (im.width - rail_w, 0))
    shift_x = 60
    im.paste(rail_crop, (im.width - rail_w - shift_x, 0), rail_crop)
    
    # 2. Status capsule
    status_w = 260
    status_h = 70
    status_x = im.width - rail_w - shift_x
    status_y_src = 90
    status_crop = im.crop((status_x, status_y_src, status_x + status_w, status_y_src + status_h))
    status_bg = Image.new('RGBA', (status_w, status_h), bg_color)
    im.paste(status_bg, (status_x, status_y_src))
    shift_status_down = 70
    im.paste(status_crop, (status_x, status_y_src + shift_status_down), status_crop)
    
    # 3. Bottom tab bar
    tab_w = 260
    tab_h = 320
    tab_x = im.width - rail_w - shift_x
    tab_y_src = im.height - tab_h - 60
    tab_crop = im.crop((tab_x, tab_y_src, tab_x + tab_w, tab_y_src + tab_h))
    tab_bg = Image.new('RGBA', (tab_w, tab_h), bg_color)
    im.paste(tab_bg, (tab_x, tab_y_src))
    shift_tab_up = 50
    im.paste(tab_crop, (tab_x, tab_y_src - shift_tab_up), tab_crop)
    
    im.save(output_path, 'PNG')
    return output_path

def prepare_inner_landscape_shot(input_path, output_path, target_size=(2853, 2007)):
    im = Image.open(input_path).convert('RGBA')
    if im.size != target_size:
        im = im.resize(target_size, Image.Resampling.LANCZOS)
    
    bg_color = (10, 8, 6, 255)
    clock_w = 400
    clock_h = 60
    clock_crop = im.crop((0, 0, clock_w, clock_h))
    bg_patch = Image.new('RGBA', (clock_w, clock_h), bg_color)
    im.paste(bg_patch, (0, 0))
    im.paste(clock_crop, (70, 0), clock_crop)
    
    im.save(output_path, 'PNG')
    return output_path

cards_meta = [
    {
        'id': '01_contacts_home',
        'form_factor': 'outer_closed',
        'eyebrow': 'CLIENT MANAGEMENT',
        'headline': 'Your Entire Client Roster,',
        'headline_g': 'Organized.',
        'sub': 'Seamlessly navigate customers, employees, and subcontractors with instant search.',
        'raw_shot': '/tmp/duo_dark_contacts_home.png'
    },
    {
        'id': '02_contact_detail',
        'form_factor': 'inner_open',
        'eyebrow': 'RELATIONSHIP INTELLIGENCE',
        'headline': 'Deep Contact Insight &',
        'headline_g': 'Full History.',
        'sub': 'Complete address history, signed contracts, and one-tap communication.',
        'raw_shot': '/Users/adriangutierrez/Documents/Github/softwarebygl-website/public/screenshots/ipad-customers-dark.png'
    },
    {
        'id': '03_contracts_home',
        'form_factor': 'outer_closed',
        'eyebrow': 'PROJECT WORKFLOW',
        'headline': 'Every Contract at a',
        'headline_g': 'Single Glance.',
        'sub': 'Track signed jobs, completion statuses, and revenue milestones effortlessly.',
        'raw_shot': '/tmp/duo_dark_contracts_home.png'
    },
    {
        'id': '04_contracts_calendar',
        'form_factor': 'inner_open',
        'eyebrow': 'SCHEDULE & DISPATCH',
        'headline': 'Live Calendar Sync,',
        'headline_g': 'Zero Clashes.',
        'sub': 'Visualize multi-day installations and daily crew assignments across your schedule.',
        'raw_shot': '/Users/adriangutierrez/Documents/Github/softwarebygl-website/public/screenshots/ipad-calendar-dark.png'
    },
    {
        'id': '05_estimate',
        'form_factor': 'outer_closed',
        'eyebrow': 'PROPOSALS & ESTIMATES',
        'headline': 'Send Proposals That',
        'headline_g': 'Close Fast.',
        'sub': 'Crystal-clear line items, payment terms, and instant client approvals.',
        'raw_shot': '/tmp/duo_dark_estimate.png'
    },
    {
        'id': '06_business_details',
        'form_factor': 'inner_open',
        'eyebrow': 'ENTERPRISE IDENTITY',
        'headline': 'Your Business Profile,',
        'headline_g': 'Fully Governed.',
        'sub': 'Brand licensing, tax identification, and Stripe Connect deposit settings in one place.',
        'raw_shot': '/Users/adriangutierrez/Documents/Github/softwarebygl-website/public/screenshots/ipad-brand-company-dark.png'
    },
    {
        'id': '07_income_expenses',
        'form_factor': 'inner_open',
        'eyebrow': 'FINANCIAL MASTERY',
        'headline': 'Track Money In & Out,',
        'headline_g': 'With Precision.',
        'sub': 'Real-time profit tracking, expense categorization, and year-over-year analytics.',
        'raw_shot': '/Users/adriangutierrez/Documents/Github/softwarebygl-website/public/screenshots/ipad-get-paid-dark.png'
    }
]

margin_x = 160
top_y = 170

for item in cards_meta:
    # 1. Base Canvas - Luxury Gold Life Obsidian Theme
    canvas = Image.new('RGB', (W, H), '#0A0806')
    
    # Ambient Gold Blooms
    bloom1 = Image.new('RGBA', (W, H), (0, 0, 0, 0))
    bloom1_draw = ImageDraw.Draw(bloom1)
    bloom1_draw.ellipse([W - 900, -200, W + 600, 1300], fill=(214, 172, 80, 52))
    bloom1_draw.ellipse([-500, H - 1200, 900, H + 400], fill=(180, 144, 60, 40))
    bloom1 = bloom1.filter(ImageFilter.GaussianBlur(180))
    canvas.paste(bloom1, (0, 0), bloom1)
    
    # Italianno luxury watermark
    wm_img = Image.new('RGBA', (W, H), (0, 0, 0, 0))
    wm_draw = ImageDraw.Draw(wm_img)
    wm_draw.text((W - 1300, 700), 'GL', font=font_wm, fill=(201, 162, 75, 20))
    canvas.paste(wm_img, (0, 0), wm_img)
    
    # Typography Header
    draw = ImageDraw.Draw(canvas)
    draw.text((margin_x, top_y), item['eyebrow'], font=font_eyebrow, fill='#D9BE7C')
    
    headline_y = top_y + 80
    draw.text((margin_x, headline_y), item['headline'], font=font_headline, fill='#FBF8F1')
    
    headline_g_y = headline_y + 118
    draw.text((margin_x, headline_g_y), item['headline_g'], font=font_headline, fill='#E7C877')
    
    sub_y = headline_g_y + 130
    draw.text((margin_x, sub_y), item['sub'], font=font_sub, fill='#B9AE9B')
    
    # Prepare shot & composite based on form factor
    if item['form_factor'] == 'outer_closed':
        prep_path = f'/tmp/prep_{item["id"]}.png'
        prepare_outer_shot(item['raw_shot'], prep_path)
        framed_device = compose(prep_path, frame_data_outer)
        
        target_device_h = 1780
        scale = target_device_h / framed_device.height
        target_device_w = int(framed_device.width * scale)
        device_resized = framed_device.resize((target_device_w, target_device_h), Image.Resampling.LANCZOS)
        
        shadow_pad = 120
        shadow = Image.new('RGBA', (target_device_w + shadow_pad * 2, target_device_h + shadow_pad * 2), (0, 0, 0, 0))
        shadow_draw = ImageDraw.Draw(shadow)
        shadow_draw.rounded_rectangle([shadow_pad + 20, shadow_pad + 25, shadow_pad + target_device_w - 20, shadow_pad + target_device_h + 20], radius=int(90 * scale), fill=(0, 0, 0, 220))
        shadow = shadow.filter(ImageFilter.GaussianBlur(60))
        
        device_x = (W - target_device_w) // 2
        device_y = H - target_device_h - 70
        
        canvas.paste(shadow, (device_x - shadow_pad, device_y - shadow_pad), shadow)
        canvas.paste(device_resized, (device_x, device_y), device_resized)
        
    else:  # 'inner_open'
        prep_path = f'/tmp/prep_{item["id"]}.png'
        prepare_inner_landscape_shot(item['raw_shot'], prep_path)
        framed_device = compose(prep_path, frame_data_inner)
        
        target_device_w = 1800
        scale = target_device_w / framed_device.width
        target_device_h = int(framed_device.height * scale)
        device_resized = framed_device.resize((target_device_w, target_device_h), Image.Resampling.LANCZOS)
        
        shadow_pad = 120
        shadow = Image.new('RGBA', (target_device_w + shadow_pad * 2, target_device_h + shadow_pad * 2), (0, 0, 0, 0))
        shadow_draw = ImageDraw.Draw(shadow)
        shadow_draw.rounded_rectangle([shadow_pad + 25, shadow_pad + 25, shadow_pad + target_device_w - 25, shadow_pad + target_device_h + 20], radius=int(60 * scale), fill=(0, 0, 0, 220))
        shadow = shadow.filter(ImageFilter.GaussianBlur(60))
        
        device_x = (W - target_device_w) // 2
        device_y = H - target_device_h - 150
        
        canvas.paste(shadow, (device_x - shadow_pad, device_y - shadow_pad), shadow)
        canvas.paste(device_resized, (device_x, device_y), device_resized)

    out_path = os.path.join(out_dir, f'{item["id"]}.png')
    canvas.save(out_path, 'PNG', optimize=True)
    print(f'Rendered card ({item["form_factor"]}): {out_path}')

print('All 7 cards rendered with authentic Apple iPhone Duo hardware frames (both Closed Outer and Open Inner angles)!')
