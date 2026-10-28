# AI toolbox manifest (toolset `mb-1`)

This README documents the **single source of truth** for what the My Business assistant can do.
The manifests themselves live in `GLSmallBusiness/Resources/AI/`. That folder is inside the app's
synchronized group, so Xcode copies both JSON files into the app bundle (no project edit needed).
This README stays here, outside the app target, so it isn't bundled.

| File | Used by | What it is |
|---|---|---|
| `GLSmallBusiness/Resources/AI/tools.mb-1.json` | Server (`gl-business-api`, `POST /ai/turn`) and the app's tool registry | Every online tool: core, plus the areas the model loads on demand |
| `GLSmallBusiness/Resources/AI/tools.mb-1.ondevice.json` | The app's offline (Foundation Models) assistant | Read-only `find`, `get`, `report` with short descriptions (contract §6) |

## The one rule: the server copy must be byte-identical

`gl-business-api/src/ai/tools.mb-1.json` must be a **byte-for-byte copy** of
`SmallBusinessApp/GLSmallBusiness/Resources/AI/tools.mb-1.json`. The phone never sends tool definitions: the server declares
them to the model from its own copy, and the phone runs the calls. If the two copies drift, the
model can call a tool, or pass an argument, that the phone doesn't understand.

- Edit the app's copy in `GLSmallBusiness/Resources/AI/` and then copy it to the server. Never edit
  the server copy by hand.
- Check with `cmp SmallBusinessApp/GLSmallBusiness/Resources/AI/tools.mb-1.json gl-business-api/src/ai/tools.mb-1.json`.
  It must print nothing. `gl-business-api/test/ai/run.mjs` runs the same comparison.
- A change that breaks compatibility (renaming or removing a tool, a parameter or an enum value, or
  changing what an argument means) needs a new toolset id (`mb-2`) in a new file. The old file
  stays until no shipped build asks for `mb-1`. Adding an optional parameter or a new tool is fine
  in place, once the phone can run it.

The phone's executors live in `GLSmallBusiness/AI/`: `MBToolbox` loads both files from the app
bundle through GoldLifeAI's `GLAIToolbox` and binds the tools by name. The read tools (`find`,
`get`, `report`, `help`) are bound in both toolboxes; the write tools are bound ONLINE only (law
12: offline is read-only). EVERY manifest tool is bound now — the reads, the core writes, the five
areas' writes, and the six hand-offs — each a thin wrapper over a service in `Services/Domain/`
(DOMAIN-SERVICES.md has the tool → service map). Each executor takes its summary and parameters
from its manifest entry, so the two can't drift; `MBToolbox.scheduled` is empty and a test fails on
any manifest tool with no executor.

The six hand-offs (`open`, `send`, `pick_media`, `share_document`, `save_to_contacts`,
`contact_developer`) write nothing themselves: the tool checks that what it names is really there
and returns `.handoff`, and `MBAIHandoffPresenter` — mounted on the assistant screen, which stays
on screen for the whole request — shows the compose sheet, the share sheet, the picker or the
push and answers the loop with the REAL outcome (contract A5). Every refusal is decided before
anything is shown: no mail account, no recipient, an incomplete business profile (law 45), a
document that wouldn't render, a Face ID that didn't pass. A picked photo, file, scan or phone
contact is saved through the same services the screens' own importers call (`MBPickCommit`).

## Format

```json
{
  "toolset": "mb-1",
  "areas": { "<area>": "<one plain line: what this area lets you do>" },
  "tools": [
    { "name": "save_job", "area": "core", "confirm": "never",
      "summary": "<what it does, when to use it, key rules; 1-4 sentences>",
      "parameters": { "type": "object", "properties": { … }, "required": [ … ] } }
  ]
}
```

- **`name`**: `^[a-z][a-z_]{0,47}$`, unique.
- **`area`**: `core` (always sent) or one of the keys in `areas`. The model loads up to 2 areas with
  `load_tools`, and the server also loads them from what's on screen (invoice, estimate or change
  order → `money`; employee or subcontractor → `team`; receipt or job → `expenses`).
- **`confirm`**: `never`, `always` (the app always asks the person first: deletes and recorded
  money), or `conditional` (the phone decides per call, e.g. when a paid invoice is affected). The
  phone's services make the real decision; this field only documents it.
- **`summary`**: the text the model reads. Say what the tool does and when to pick it, in plain
  words. Never put display text for the person here.
- **`parameters`**: a JSON Schema object using only `type`, `description`, `properties`,
  `required`, `items`, `enum`, `minimum`, `maximum`, `minItems`, `maxItems`, `nullable`.
  - Property names are `snake_case`, and every property has a `description`.
  - Enum values are the app's real raw values (`squareFoot`, `dueOnReceipt`, `inProgress`, …).
  - Money and quantities have `minimum: 0`. Credits exist only as `is_credit` on change orders.
    Percentages have `maximum: 100`.
  - Dates are strings. Each description says whether it's a date (`YYYY-MM-DD`) or an ISO 8601
    date-time.
  - Ids are record ids returned by `find` or `get`.
  - `nullable: true` marks a field where `null` clears the value (e.g. a job's agreed price).

## Limits

- `core` has at most 20 tools, and each area at most 8.
- On-device tools: descriptions of 12 words or fewer, and 4 parameters or fewer.
- Keep descriptions tight. The manifest is sent to the model on every step.
