# Log entry template — copy a block into `LOG.md`, fill it in, save

Keep it short and factual so the next person can actually reproduce / avoid repeating it. Append new entries at the TOP of `LOG.md`.

## If you TRIED something

```
### [YYYY-MM-DD] — <your name>
**Issue:** #<n> (link/what it is)
**What I tried:** <what you changed / ran>
**How I tested it:** <steps + how you verified (parts count, attr, etc.)>
**Result:** ✅ worked / ❌ no change / 🔍 partial — <numbers>
**Notes / next lead:** <what someone should try next>
```

## If you're REQUESTING / suggesting

```
### [YYYY-MM-DD] — <your name>
**Type:** 💡 idea / 🙋 request / ❓ question
**About:** <feature or issue>
**Details:** <what you want, why, any acceptance criteria>
```

## Ground rules

- Read `docs/PAINT-PIPELINE.md` before changing paint code (everything is server-enforced; <40 studs; caps are real).
- Verify with **live part counts**, not the `PaintCount` attribute (it lags and is lifetime-inflated).
- Don't wire `Misc.GiveAllGamePasses` or other obviously-server-validated shortcuts — they get accounts flagged.
- Double-check before claiming "fixed": reproduce the bug first, then show the fix changes the number.
- Keep the script re-exec safe (no permanent side-effects if run twice).
