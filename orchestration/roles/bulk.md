# Role: bulk  (model: DeepSeek — API)

**Lane:** cheap, high-volume SFW work — first-pass expansion, bulk reformatting (brief §6).
**Class:** MODERATED — the official DeepSeek API is censored and logs violations; **SFW only**, never explicit.

## When to use
`--bulk` first drafts of SFW material, large parallel passes where cost matters more than polish.

## Constraints
- Needs `DEEPSEEK_API_KEY` in `.env`. Not first-party-subscription; pay-per-token.
- Leak guard applies (explicit content aborts the call).
- Proposes to `drafts/`; never writes `manuscript/`.
