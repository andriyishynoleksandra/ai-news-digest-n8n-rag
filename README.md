# AI News Digest

n8n workflow that runs daily, fetches AI/ML news from three sources (TechCrunch AI, The Verge AI, HuggingFace blog), filters out items the system already covered in the last 30 days (anti-duplicate via vector similarity), classifies the rest with an LLM, and writes a structured digest row per news item to Google Sheets.

The interesting design choice here is the **anti-duplicate RAG layer**: when several outlets publish about the same announcement in different days, vector similarity catches the repeat and the workflow skips it, so the Sheet stays one row per story rather than one row per *report* of the story.

## Pipeline

```
Schedule (09:00 daily)
   ↓
3× RSS (TechCrunch AI, The Verge AI, HuggingFace) → Merge → Normalize (strip HTML)
   ↓
Deduplicate by URL (against existing Sheet rows)
   ↓
Limit (cap items per run)
   ↓
─── Loop over items ───
   ↓
OpenAI embedding (text-embedding-3-small, 1536d)
   ↓
Supabase RPC match_news_archive (cosine similarity over last 30 days)
   ↓
IF similarity > 0.85 → SKIP (already covered)
                    ↓ no
LangChain AI Agent (Gemini 2.5 Flash Lite, JSON output)
   ↓
Parse LLM JSON → { category, summary, importance }
   ↓
Supabase INSERT news_archive (saves embedding for future dedup)
   ↓
Google Sheets append (one row per story)
```

## What it demonstrates

- **Anti-duplicate RAG** — embeddings used not for retrieval-then-generate, but as a *filter*: skip news whose embedding cosine-matches anything in the 30-day archive. Same vector stack, different application of it than the textbook RAG pattern.
- **Workflow orchestration in n8n** — schedule, branching, looping, error handling, structured retries — declarative rather than glued together in Python.
- **Two-layer dedup** — URL-level (against Sheets) catches exact reposts; vector-level (against Supabase archive) catches the same *story* from different outlets.
- **pgvector on Supabase** — `vector(1536)` column + `ivfflat` cosine index + custom RPC `match_news_archive` for time-windowed similarity search.
- **Structured LLM output** — fixed category taxonomy in the system prompt so categorization is consistent across runs, plus strict JSON-only output and a JSON-parse fallback for malformed responses.
- **Cost-aware** — Gemini 2.5 Flash Lite chosen over GPT-4o-mini for ~5× lower per-token cost; `text-embedding-3-small` over `large` for ~5× lower embedding cost.

## Cost per news item

Measured on Gemini 2.5 Flash Lite + `text-embedding-3-small`:

| Component | Tokens | Cost |
|---|---|---|
| Embedding (query) | ~150 | $0.000003 |
| Gemini prompt | ~400 | $0.00004 |
| Gemini completion | ~80 | $0.000032 |
| **Total per news** | | **~$0.00008** |

At ~30 new items per day (after dedup) that's about **$0.07/month** for LLM + embeddings. RSS and Supabase free tier cover the rest.

## Repository layout

```
ai-news-digest/
├── README.md                  — this file
├── workflow.json              — importable n8n workflow
├── setup_supabase.sql         — pgvector + table + RPC
└── docs/
    └── architecture.png       — pipeline diagram (optional)
```

## Setup

### 1. Supabase

1. Create a new Supabase project at https://supabase.com (free tier is enough)
2. Open SQL Editor → paste `setup_supabase.sql` → Run
3. Note your project URL and **service role** key (Settings → API)

### 2. Google Sheet

Create a Sheet with these column headers in row 1:

```
run_date | url | title | source | category | importance | summary | published_at
```

Then File → Share → Publish to the web → Comma-separated values (.csv) — copy the published URL (this is used for URL-level deduplication in `Deduplicate by URL` node).

### 3. n8n

1. Import `workflow.json` into n8n (Workflow → Import from File)
2. In the credentials sidebar, add:
   - **Google Sheets OAuth2** (used by `Append to Sheet`)
   - **Google Gemini PaLM API** (used by `Google Gemini`)
3. Wire credentials into both nodes
4. Replace placeholders in three Code nodes:
   - `Deduplicate by URL` → `SHEETS_CSV_URL`
   - `OpenAI Embedding` → `OPENAI_API_KEY`
   - `Archive Lookup` and `Save to Archive` → `SUPABASE_URL` + `SUPABASE_KEY`
   - `Append to Sheet` → `documentId` (Google Sheets ID from your sheet's URL)
5. Activate the workflow

> **Production note:** the workflow inlines API keys in Code nodes for clarity. In production move them to n8n credentials and reference via `$credentials`.

## Design choices and trade-offs

**Why anti-duplicate instead of clustering by topic?**
Clustering all daily news into topical groups is a different product — a "daily digest" with sections. Here the goal is a clean *event log*: one row per story, no repeats. Anti-duplicate is the minimum viable filter for that.

**Why 0.85 similarity threshold?**
Empirically: below 0.80 the system started flagging genuinely different stories about the same company (e.g. OpenAI funding + OpenAI model release in same week) as duplicates. Above 0.90 it missed obvious reposts (same announcement, different outlet, paraphrased title). 0.85 is the sweet spot for this corpus. For a different corpus it should be re-tuned with labeled pairs.

**Why three RSS sources, not ten?**
RSS feed pollution: most "AI" feeds catch too much off-topic (e.g. generic tech, hardware reviews). The three picked have the highest signal-to-noise for frontier AI news. Adding more sources without quality filtering would just feed the dedup layer more work.

**Why Gemini, not GPT?**
For a classification + 2-sentence summary task there's no quality reason to pay 5–30× more for GPT-4-class models. Gemini 2.5 Flash Lite handles the schema reliably with temperature 0.2.

**Why Supabase, not just store embeddings in Sheets?**
You *could* store base64-encoded embeddings in a Sheet cell. You shouldn't: cosine similarity on 30-day windows of 1500-dim vectors is what pgvector exists for. A spreadsheet read + JS loop would work for ~100 rows; at 1000+ rows it falls apart.

## What's next

- **Telegram/Slack digest** — at the end of each daily run, post a markdown summary of the day's `importance=high` items
- **Better importance signal** — currently LLM-judged from a single article snippet; could incorporate social signals (HackerNews score, Twitter mentions)
- **Per-source category bias correction** — TechCrunch over-weights funding, HuggingFace over-weights research; observable in the Sheet
- **Evaluation harness** — labeled (article_A, article_B, is_same_story) pairs to tune the dedup threshold quantitatively rather than by eye

## Stack

n8n · Supabase (Postgres + pgvector) · OpenAI Embeddings · Google Gemini 2.5 Flash Lite · LangChain Agent node · Google Sheets API
