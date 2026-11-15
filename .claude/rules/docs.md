---
paths:
  - "*.md"
  - "lvi.1.scd"
  - "contrib/**"
---

# Documentation (who each doc is for)

Five docs, five audiences — keep content in its lane and don't duplicate across them. **Prose in all of them follows the repo voice — see `.claude/voice.md`; evaluate any new or changed doc prose against it (and run its final pass) before calling the change done.**

- **`lvi.1.scd` (the manpage)** — source of truth for day-to-day editor use: normal-mode commands, ex commands, config, environment. GitHub renders `.scd` inline, so it doubles as browsable reference. It mentions the `contrib` tools only as a brief "this exists, turn it on" teaser with headliners, then links out. **scdoc trap** (has bitten repeatedly): a wrapped continuation line must never start with `-` — the house style's ` -- ` dashes land there easily and scdoc parses the line as a list entry, breaking the build. Rewrap so the dash sits mid-line or at line end, and validate every edit with `scdoc < lvi.1.scd > /dev/null`.
- **contrib script header comments** — the verbose per-script operator reference: purpose, invocation/synopsis, every env knob, binding snippets, debug flags. Self-contained when you open the file. Env knobs live *here only*.
- **`contrib/README.md`** — the tour/pitch: what each tool is *for*, and the cross-cutting machinery no single script owns (the `:hl` overlay substrate, file-backed lists + focus, the three spawn disciplines, the backend contract). Points *into* the headers rather than re-listing knobs.
- **`VIM.md`** — the arriving vim user, read once: what to install first, the habits to relearn (`:help` → the manpage and `\c`, long `:` lines → the command window, path work → `:sh`), a rosetta table of vim features and popular plugins mapped onto the lvi key/tool/rc line, and a "what isn't coming back" section. It duplicates no reference: every row points at the manpage or a contrib header. A row's answer is usually a contrib tool plus an rc line, so **a renamed or retired tool must be fixed here too** — grep `VIM.md` when contrib changes.
- **`README.md`** — overview and sales pitch, cascading high→low: the pitch, quick start, a short "what you get" teaser (defers to the manpage for the full reference), then the "Design & implementation" rationale near the end. Prominent links to the manpage, `contrib/`, and `VIM.md` sit up top.
