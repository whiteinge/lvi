# Voice: lvi docs

The voice model for `README.md`, `contrib/README.md`, and the prose parts of
`lvi.1.scd`. This governs *voice* — stance, rhythm, diction. *Format* (scdoc
rules, link style, wrapping, which doc owns what) follows `CLAUDE.md` §
Documentation. Where the two meet — em-dash use especially — voice wins: the
format is legal, the question here is whether it's *earning its keep*.

## Stance

The docs are well-crafted; the failure mode is *over*-crafting. No single
sentence is wrong — the density of rhetorical moves is, and that density is what
reads as machine-generated to a newcomer who isn't sold yet. A person writing
docs varies the rhythm and lets plain sentences be plain. Write to inform; reach
for a rhetorical move only when it does work a plain sentence can't.

## Two registers

lvi is a deviation from vi, so the docs do two jobs, each with its own register.

### Debate register — the sales and defense passages

The claim → response passages: getting out in front of a purposefully-missing
feature, or selling an unusual addition (e.g. README's *Why lvi* and *What it
isn't*, the manpage's *Without visual mode* table).

- **Lead with the inversion; state the counter as fact.** "No visual mode" isn't
  an apology — the counter *is* the headline: "The operator + motion +
  text-object model covers its uses." (The debater's "Compared to who?" applied
  to a feature.)
- **Terse, declarative, telegraphic.** Fragments are fine. Cut throat-clearing
  and closers.
- **Keep a sharp antithesis; cut the scaffolding that sets it up.** The *out* /
  *in* pairing is good — an inversion stated flat. "vi has always been great at
  calling ... adds the missing half" is scaffolding around it. Strip the
  scaffolding, keep the antithesis bare.
- **Gloss jargon inline** for the reader who doesn't know the term yet.

### Explainer register — the rationale and tour

The teach-the-design passages (README's *Design & implementation*,
`contrib/README.md`, the manpage's section intros).

- **Open on the concrete subject or why-it-matters, not a verdict-clause or
  hook.** "A few design decisions shape the rest of lvi," not "The interesting
  part isn't the vi commands — it's ..."
- **Teach the *why*** — the mental model before the recipe (the motion→target /
  operator→range contract, the stdin/stdout filter contract).
- **Understated, genuine enthusiasm.** Let the design speak and the reader
  conclude it's clean; don't announce that it is.
- **Close flat.** "That's it." No grand flourish.
- **Honest caveats**, hedged to match reality (nowrap-only, MVP status).
- Dry asides and a `:-)` land better than a joke.

## House format notes

- **Emoji are fine in `README.md`** as wayfinding/link markers (📖 🧰 👉) — it
  sells better in a public-facing front door. Prose emphasis elsewhere stays
  text: italics for a single word, bold for the one takeaway, `:-)` not 🙂.

## Before / after

**Debate register — strip scaffolding, keep the antithesis:**

> ~~vi has always been great at calling *out* to the shell (`!`, `:r !`,
> filters). `lvi` adds the missing half: every running editor exposes a
> **control socket**, so a shell script, a `Makefile`, a linter, or a five-line
> client in any language can call *in* — send it commands and read back its
> state.~~
>
> vi calls *out* to the shell — `!`, `:r !`, filters. lvi adds the way *in*:
> every running editor exposes a control socket, so a script, a Makefile, or a
> linter can send it commands and read its state back.

**Explainer register — open on the subject, drop the reveal and the self-praise:**

> ~~The interesting part of `lvi` isn't the vi commands — it's a handful of
> design decisions that turned out unusually clean, and reinforce each other.~~
>
> A few design decisions shape the rest of lvi. Each is small; together they're
> why it needs no build step, no plugin runtime, and no embedded scripting
> language.

**Explainer register — cut the flourish clause:**

> ~~so `lvi` never binds it: **raw mode is done by shelling out to `stty`**,
> which is pure Lua, zero ABI, and is itself the project philosophy in
> miniature.~~
>
> so lvi never binds it: raw mode shells out to `stty` — pure Lua, zero ABI.

## Anti-patterns

- **The setup-and-reveal.** "vi has always been great at X ... lvi adds the
  missing half"; "The interesting part isn't X — it's Y." A hook dressed as
  information. State the thing.
- **Flourish clauses.** "is itself the project philosophy in miniature," "the
  firewall keeping the core from drifting," "The quiet win is the funnel
  itself." Cut them.
- **Essay verbs.** No "underscores / highlights / reaches for / lays bare."
  Plain verbs.
- **Self-congratulation about the code.** "unusually clean," "the quiet win."
  State what it does; let the reader judge.
- **Decorative metaphor as a label.** Name structural things literally. A
  precise antithesis earns its keep (*out* / *in*); a metaphor used only to
  frame or label does not — "three front doors" → "three entry points," "the
  UNIX-as-IDE bet" → "an implementation of UNIX as IDE," "this file is the tour"
  → "the overview." Reserve figurative language for where it clarifies, not
  where it decorates.
- **Em-dash overload.** Most sentences shouldn't need one. A period or comma
  usually does the job; keep the dash for a genuine aside or a sharp antithesis.
- **Uniform bold lead-ins** on every bullet, until the emphasis means nothing.
  Bold the one takeaway.
- **Roster padding.** Two examples land it; don't stack four ("a shell script, a
  Makefile, a linter, or a five-line client in any language").
- **Meta-caveats.** Hedge the *claim* to match reality, then say it plainly —
  don't narrate the hedge.

## Lexical tics to grep for

A fast first pass before the judgment read:

```
missing half | turned out | in miniature | the quiet win | firewall
| first-class | underscores\? | highlights that | reaches for | lays bare
```

## The pass

Run this as the last step before calling a prose change done — the same reflex
as the test suite before calling code finished. Reread each changed passage
against the anti-patterns, reading as an adversary would: author-blindness is the
trap, since you wrote it and it reads fine to you. When a whole section is in
doubt, get fresh eyes (a subagent given only this file plus the new prose, asked
to flag deviations). When a tic keeps recurring across sessions, promote it into
the anti-patterns above with a before/after exemplar — an exemplar beats a
description.
