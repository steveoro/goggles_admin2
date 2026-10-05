# Ollama Extraction — Operational Notes & Pitfalls

Lessons learned while building `PdfManifests::Extractor` (meeting manifest → LT4 JSON) against a local Ollama server (v0.35.x). These apply to any feature that asks a small local LLM for **structured JSON over a long input** — the failure modes are silent and look like "the model is dumb" when they're really transport/config issues.

## TL;DR — options that actually work

```jsonc
{
  "model": "gemma4:e4b",
  "prompt": "...",
  "stream": false,
  "think": false,
  "format": "json",
  "options": {
    "temperature": 0.1,
    "num_predict": 8192,
    "num_ctx": 16384      // ← the one everyone forgets
  }
}
```

The same `options` hash applies to both `/api/generate` and `/api/chat`.

## 1. `num_ctx` is the silent truncator (done_reason=length)

Ollama's default context window is **4096 tokens**, shared by prompt **and** output. If the prompt is ~3300 tokens, the response dies at ~748 tokens **regardless of `num_predict`** — mid-JSON, no error, `done_reason: "length"`.

Symptoms seen on `manifest-…-Belluno.pdf` (3346 prompt tokens):

```
eval_count=748   done_reason=length   → truncated JSON, deterministic cutoff
```

Diagnostics — always check these fields on the response:

| field               | meaning                                        |
|---------------------|------------------------------------------------|
| `prompt_eval_count` | tokens consumed by the prompt                  |
| `eval_count`        | tokens generated                               |
| `done_reason`       | `stop` = clean finish; `length` = hit a limit  |

Rule of thumb: `num_ctx >= prompt_eval_count + expected_output_tokens + margin`. Manifests are 2–4 pages: `num_ctx: 16384` covers everything seen so far. Bigger values cost RAM/KV-cache; don't set 128k "just in case" on small GPUs.

## 2. `think: false` for reasoning-capable models

`gemma4:e4b` advertises a `thinking` capability. With thinking left on, the model can burn the whole generation budget on hidden reasoning and emit a truncated/empty `response`. Always pass `"think": false` (top level, not inside `options`) for extraction work.

## 3. `format: "json"` helps, but doesn't save you

- It constrains output to valid JSON *when the model gets that far* — it does nothing about context truncation (the ~748-token cutoff happened identically with and without it).
- It does **not** validate against your schema: missing keys, wrong types and hallucinated values are still your job (`Lt4Builder` exists for that reason).
- Keep a **parse + one retry** loop anyway: `OllamaClient#generate` retries once on `JSON::ParserError`, then raises.

## 4. Small models: few-shot beats abstract rules

Telling the model "split dash-separated events" failed repeatedly — it swallowed `800SL (1 per corsia) max 80 iscritti - 50FA – 50RA – 1 0 0 S L –200MX` as a single event. One concrete example in the prompt fixed it permanently:

> Example: the line `"inizio gare 800SL (1 per corsia) max 80 iscritti - 50FA – 50RA – 1 0 0 S L –200MX"` yields exactly FIVE events: 800SL, 50FA, 50RA, 100SL, 200MI.

Notes:
- Cover **all dash variants**: `-`, `–` (en), `—` (em) all appear in real PDFs.
- PDF text extraction produces letter-spaced tokens (`1 0 0 S L`); name them explicitly in the prompt.
- temperature `0.1` keeps few-shot behavior deterministic.

## 5. Don't trust the model's own flags/fields verbatim

Observed real failure: `{"distance": 200, "stroke": "MX", "relay": true, "raw_label": "200MX"}` — the model flagged a *misti* (medley) individual event as a relay. `Lt4Builder` therefore derives `is_relay` from textual evidence (`staffetta`/`mistaffetta`, `NxM` patterns), not from the `relay` boolean. Same story for dates: the model picked a registration-deadline date over the competition day. Normalize, cross-check (e.g. filename date), warn, keep `raw_label` for human review.

## 6. Checking capabilities — `/api/tags`

Don't assume a model can do vision (or tools). Query the tag list; each model carries a `capabilities` array:

```bash
curl -s http://localhost:11434/api/tags | \
  python3 -c "import json,sys; [print(m['name'], m.get('capabilities')) for m in json.load(sys.stdin)['models']]"
```

```
gemma4:e4b                 ['completion', 'vision', 'tools', 'thinking', 'audio']
qwen3.5:4b                 ['completion', 'vision', 'tools']
nomic-embed-text:latest    ['embedding']
```

`OllamaClient#vision_available?` does exactly this before attempting the `pdftoppm` → images fallback for scanned PDFs.

## 7. Vision calls

Images go as base64 strings in the top-level `images` array on `/api/generate` (or per-message on `/api/chat`):

```ruby
res = RestClient.post('http://localhost:11434/api/generate', {
  model:  'gemma4:e4b',
  prompt: PdfManifests::ExtractionPrompt.build_for_images,
  images: [Base64.strict_encode64(File.binread('page-1.png'))],
  stream: false, think: false, format: 'json',
  options: { temperature: 0.1, num_predict: 8192, num_ctx: 16_384 }
}.to_json, content_type: :json)
JSON.parse(res.body).dig('response') # => JSON string, parse again
```

Rendered at 150 DPI a page is ~1–2k tokens of vision context — `num_ctx` still applies (image tokens count too).

## 8. Timeouts and flaky models

- Generation on a 7B model takes 10–60 s for a manifest page-set. Use a long `read_timeout` (300 s) and a short `open_timeout` (3 s) so a dead server fails fast but a busy one can finish.
- `qwen3.5:4b` timed out (`Timed out reading data from server`) on the same prompt `gemma4:e4b` handled — model choice matters; keep it configurable (`OLLAMA_MANIFEST_MODEL`).
- `/api/generate` and `/api/chat` showed identical truncation/behaviour in testing; we use `/api/generate` because it's one flat call.

## 9. Reproduce / debug quickly

```bash
# Full request, check the counters first:
curl -s http://localhost:11434/api/generate -d '{
  "model": "gemma4:e4b",
  "prompt": "…your prompt…",
  "stream": false, "think": false, "format": "json",
  "options": {"temperature": 0.1, "num_predict": 8192, "num_ctx": 16384}
}' | python3 -c "import json,sys; j=json.load(sys.stdin);
  print('prompt_tokens:', j['prompt_eval_count'], 'eval:', j['eval_count'], 'reason:', j['done_reason']);
  open('/tmp/ollama_out.txt','w').write(j['response'])"

# Sanity-check that num_predict is honored at all (should yield ~1700+ eval):
curl -s http://localhost:11434/api/generate -d '{"model":"gemma4:e4b",
  "prompt":"List the integers from 1 to 300 as a JSON array, nothing else.",
  "stream":false,"format":"json","options":{"num_predict":3000,"temperature":0.1}}' \
  | python3 -c "import json,sys; j=json.load(sys.stdin); print(j['eval_count'], j['done_reason'])"

# From Rails (what Extractor does):
bundle exec rails runner "
  r = PdfManifests::Extractor.new.call('crawler/data/manifests/262/manifest-….pdf', force: true)
  puts [r.success?, r.events_count, r.skipped_reason, r.warnings].inspect"
```

## Reference

Implementation: `app/strategies/pdf_manifests/` (`OllamaClient::GENERATE_OPTIONS` holds the tuned defaults). Pipeline doc: `docs/pdf_processing/manifest_extraction.md`.
