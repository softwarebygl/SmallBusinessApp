# My Business — DARK-NATIVE iPad App Store panel set, v2 (2026-10-11)
#
# Adheres strictly to the Gold Standard and Adrian Gutierrez's directives:
#   • Authentic screenshots from the real iPad 3-column split view (EST-0001, CON-0003, INV-0001, etc.)
#   • Framed in the official Apple iPad Pro 13" landscape hardware frame.
#   • Canvas: Landscape 2752x2064 (exact App Store Connect slot dimension for iPad 13" display).
#   • Gold Life obsidian dark luxury aesthetic with ambient gold lighting, floor glow, subtle Italianno watermark, and the official GL APPROVED seal.
#   • Punchy poster typography: Eyebrow, 2-line headline with gold gradient accent (.g), clear subtitle.

PD = "ipad"
K = {"ipad": 1.28}

def _left(**kw): return dict(style="left:150px;width:860px;top:280px;", **kw)
def _dev(screen, tilt="s", w=1700, x=1020, top=740, th=44):
    # Device right edge lands at ~2720px (inside 2752px canvas, with clear breathing room)
    return dict(screen=screen, tilt=tilt, w=w, side="left", x=x, top=top, thickness=th)

IPAD = [
  # 1 — PROPOSALS & ESTIMATES (Itemized estimate EST-0001, Master Bath Tile)
  dict(id="01_estimate", canvas=PD, theme="black", wm="font-size:1700px;left:-300px;top:500px;",
       key="width:1800px;height:1800px;left:-500px;top:-700px;",
       floor="width:2200px;height:600px;left:700px;top:1780px;",
       cornerseal="right:150px;top:150px;",
       pad=_left(eyebrow="PROPOSALS & ESTIMATES", poster=True,
                 headline="Send proposals that<br><span class='g'>close fast.</span>",
                 sub="Itemized line items, clear totals, and client approvals."),
       device=_dev("estimate")),

  # 2 — CONTRACTS & SIGNATURES (CON-0003 Luxury Vinyl Plank, signed on device)
  dict(id="02_contract", canvas=PD, theme="black", wm="font-size:1700px;right:-400px;top:300px;",
       key="width:1800px;height:1800px;left:-500px;top:-700px;",
       floor="width:2200px;height:600px;left:700px;top:1780px;",
       pad=_left(eyebrow="PROJECT WORKFLOW", poster=True,
                 headline="Signed contracts,<br><span class='g'>legally sealed.</span>",
                 sub="Capture legally binding physical signatures on device."),
       device=_dev("contract")),

  # 3 — MILESTONE INVOICING (INV-0001 Luxury Vinyl Plank, partially paid, export PDF)
  dict(id="03_invoice", canvas=PD, theme="black", wm="font-size:1700px;left:-300px;top:400px;",
       key="width:1800px;height:1800px;left:-500px;top:-700px;",
       floor="width:2200px;height:600px;left:700px;top:1780px;",
       pad=_left(eyebrow="INVOICES & BILLING", poster=True,
                 headline="Milestone billing,<br><span class='g'>paid on time.</span>",
                 sub="Transform estimates into professional invoices in one tap."),
       device=_dev("invoice")),

  # 4 — LIVE SCHEDULING & DISPATCH (All Jobs Calendar, multi-day crew schedule)
  dict(id="04_calendar", canvas=PD, theme="black", wm="font-size:1700px;right:-400px;top:300px;",
       key="width:1800px;height:1800px;left:-500px;top:-700px;",
       floor="width:2200px;height:600px;left:700px;top:1780px;",
       pad=_left(eyebrow="SCHEDULE & DISPATCH", poster=True,
                 headline="Live calendar sync,<br><span class='g'>zero clashes.</span>",
                 sub="Visualize multi-day crew assignments and job schedules."),
       device=_dev("calendar")),

  # 5 — CLIENT RELATIONSHIPS & CRM (Danielle Carter, full job & address history)
  dict(id="05_customers", canvas=PD, theme="black", wm="font-size:1700px;left:-300px;top:400px;",
       key="width:1800px;height:1800px;left:-500px;top:-700px;",
       floor="width:2200px;height:600px;left:700px;top:1780px;",
       pad=_left(eyebrow="CLIENT MANAGEMENT", poster=True,
                 headline="Your client roster,<br><span class='g'>fully organized.</span>",
                 sub="Complete job history, service addresses, and instant contact."),
       device=_dev("customers")),

  # 6 — CREW HOURS & PAYROLL (Owen Caldwell, $28/hr, payday calculations)
  dict(id="06_employees", canvas=PD, theme="black", wm="font-size:1700px;right:-400px;top:300px;",
       key="width:1800px;height:1800px;left:-500px;top:-700px;",
       floor="width:2200px;height:600px;left:700px;top:1780px;",
       pad=_left(eyebrow="CREW MANAGEMENT", poster=True,
                 headline="Track crew hours &<br><span class='g'>run payroll.</span>",
                 sub="Hourly wage tracking and automated payday calculations."),
       device=_dev("employees")),

  # 7 — ENTERPRISE IDENTITY (Summit Tile & Stone, logo branding, licensing)
  dict(id="07_brand_company", canvas=PD, theme="black", wm="font-size:1700px;left:-300px;top:400px;",
       key="width:1800px;height:1800px;left:-500px;top:-700px;",
       floor="width:2200px;height:600px;left:700px;top:1780px;",
       pad=_left(eyebrow="ENTERPRISE IDENTITY", poster=True,
                 headline="Your business profile,<br><span class='g'>fully governed.</span>",
                 sub="Custom branding, contractor licensing, and credentials."),
       device=_dev("brand_company")),

  # 8 — PAYMENTS & DEPOSITS (Stripe Connect direct deposits & invoice pay button)
  dict(id="08_get_paid", canvas=PD, theme="black", wm="font-size:1700px;right:-400px;top:300px;",
       key="width:1800px;height:1800px;left:-500px;top:-700px;",
       floor="width:2200px;height:600px;left:700px;top:1780px;",
       cornerseal="right:150px;top:150px;",
       pad=_left(eyebrow="PAYMENTS & DEPOSITS", poster=True,
                 headline="Accept card payments,<br><span class='g'>straight to bank.</span>",
                 sub="Stripe Connect deposits with automated bookkeeping."),
       device=_dev("get_paid")),
]
