# CLAUDE.md — My Business (GLSmallBusiness)

**Before ANY UI or behavior work, read the design system in the sibling repo `../GoldLifeUI/`:**
- **REQUIREMENTS.md** — the LAW BOOK: behaviors, placements, invariants every GL app obeys
  (banner slot, live language switching, offline semantics, alert+log, sign-out cache…).
- **PARITY.md** — what must match across apps, surface by surface (the Gate, Menu, banners…).
- **DESIGN.md** — how things look: button ranks, cards, palette (adaptive: cream light,
  black-gold dark).
- The **GoldLifeUI package** (imported via SPM) — use its components; never re-create one.

Standing rules: an instruction to one app is a change to EVERY app the same turn; the done-gate
diffs against PARITY.md + REQUIREMENTS.md; a new durable ruling lands in REQUIREMENTS.md the
same turn it is made. App-specific state: README.md here + the memory store
`~/.claude/projects/-Users-adriangutierrez-Documents-Github-SmallBusinessApp/`.
