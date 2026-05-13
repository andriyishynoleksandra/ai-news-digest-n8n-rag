-- =====================================================
-- AI News Digest — Supabase setup
-- =====================================================
-- Run this in Supabase SQL Editor on a fresh project.
-- Creates:
--   1. pgvector extension
--   2. news_archive table (with vector(1536) for OpenAI embeddings)
--   3. match_news_archive() RPC for cosine-similarity search

-- 1. Enable pgvector
create extension if not exists vector;

-- 2. Archive table
create table if not exists news_archive (
    id            bigserial primary key,
    url           text unique not null,
    title         text not null,
    source        text not null,                -- e.g. 'TechCrunch AI'
    category      text,                          -- one of fixed categories (set by LLM)
    summary       text,                          -- 1-2 sentence summary in EN
    importance    text,                          -- 'high' | 'medium' | 'low'
    published_at  timestamptz,
    embedding     vector(1536),                  -- OpenAI text-embedding-3-small
    created_at    timestamptz default now()
);

-- Index for vector similarity (ivfflat, good for <1M rows)
create index if not exists news_archive_embedding_idx
    on news_archive
    using ivfflat (embedding vector_cosine_ops)
    with (lists = 100);

-- Index for time-window filtering
create index if not exists news_archive_created_at_idx
    on news_archive (created_at desc);

-- 3. RPC: find similar archived news within a time window
-- Returns rows where cosine similarity > threshold,
-- only considering items added in the last `days_back` days.
create or replace function match_news_archive (
    query_embedding   vector(1536),
    days_back         int,
    match_threshold   float,
    match_count       int
)
returns table (
    id            bigint,
    url           text,
    title         text,
    source        text,
    category      text,
    published_at  timestamptz,
    similarity    float
)
language sql stable as $$
    select
        n.id,
        n.url,
        n.title,
        n.source,
        n.category,
        n.published_at,
        1 - (n.embedding <=> query_embedding) as similarity
    from news_archive n
    where
        n.created_at > now() - (days_back || ' days')::interval
        and 1 - (n.embedding <=> query_embedding) > match_threshold
    order by n.embedding <=> query_embedding
    limit match_count;
$$;
