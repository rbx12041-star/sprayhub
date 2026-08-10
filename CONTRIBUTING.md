# Contributing to SprayHub

Welcome, helper. Here's how to add value *without* turning the repo into spaghetti. Read `docs/PAINT-PIPELINE.md` before touching paint logic — everything is server-enforced and the caps are real.

## The loop (every contribution, big or small)

1. **Sync.** `git pull origin master` so you're current. Never work off a stale copy.
2. **Pick / file a focus.** Look at `docs/ISSUES.md` and the [Issues](../../issues) tab. Working on something new? Open an Issue first (templates provided) so nobody duplicates you.
3. **Branch.** One fix/topic per branch — `git checkout -b fix/multicolor-flush` or `feature/image-painter`. Never commit unfinished work straight to `master`.
4. **Understand first.** Reproduce the bug and log the *failure numbers* before you change anything (see "Verify" below). Guessing fixes wastes everyone's time.
5. **Test in-game for real.** Run `sprayhub.luau` on your own account and confirm the fix with live paint counts.
6. **Document it.** Update the three tracking files (below). A fix with no paper trail doesn't count.
7. **Open a Pull Request.** Fill the PR template. @Sebiy (or whoever owns the area) reviews → merge.

## Files you update when you finish something

| You changed… | Update |
|---|---|
| Script behavior | `CHANGELOG.md` (new version line) |
| A bug's status / tried a fix | `docs/ISSUES.md` (mark ✅/❌/🔍 + notes) |
| Anything you did or learned | `LOG.md` (new entry on top, use `docs/LOG-template.md`) — this is the "who tried what" record |
| New feature/module | `README.md` status table + docs |

## Verify (non-negotiable)

- Prove paint with **live part counts**: number of non-`Client` `BasePart`s under `workspace.PaintFolder[LocalPlayer.Name]` before vs after.
- The `PaintCount` attribute is a **lifetime counter that lags ~1–2 s** — a single early read is a false negative. Wait, and read actual parts.
- Test on a **fresh, big, flat wall**, within **40 studs** of your character.

## Do / don't

**Do**
- Keep the script **re-exec safe** (running it twice must not break or double-up loops/UI).
- Keep commits focused + descriptive ("fix: group image pixels by color before flush").
- Ask questions in an Issue's thread instead of silently re-deriving something already in `docs/` or `LOG.md`.

**Don't**
- Don't wire obviously server-validated cheats (`Misc.GiveAllGamePasses`, spoofing `GamePasses`), don't spam bursts — these get accounts flagged.
- Don't claim "fixed" without the before/after numbers.
- Don't force-push to `master`.

## Optional discipline

- Enable branch protection (require PR for `master`) under Settings → Branches once a few people are active.
- Use labels: `bug`, `blocked`, `needs-verification`, `idea`, `high-pri`.

## If your change isn't done yet

Push a **draft PR** with `[WIP]` in the title so others see the direction — don't sit on a local branch for days.
