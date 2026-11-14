# RAG and GraphRAG retrieval survey (September 2026)

Collected for `design-docs/specs/note-retrieval-fusion.md`. Numbers are quoted from the abstracts, HTML full texts, or vendor blogs named in each row; items marked "unverified" were seen only in search excerpts.


Survey date: 2026-09-03. Searches run: 32 web searches plus about 40 abstract or full-text fetches (arXiv abs pages, arXiv HTML full texts, Microsoft Research and Anthropic engineering blogs). Every number below was read from an arXiv abstract, an arXiv HTML full text, a vendor blog, or a search-engine excerpt. Where a number came only from a search excerpt and the page itself could not be opened, it is marked "unverified".

Target system: notes stored in SQLite with FTS5 (trigram tokenizer, bm25 ranking), notes carry tags (hierarchical tag tree, tags have classes), explicit note-to-note links, notebooks, and an LLM agent that calls a `search` tool over the notes. No embedding model and no external vector database.

---

## 1. Paper table

| # | Title (authors, year) | URL | Core idea | Reported gain (where seen) |
|---|---|---|---|---|
| 1 | HippoRAG (Gutiérrez, Shu, Gu, Yasunaga, Su; NeurIPS 2024) | https://arxiv.org/abs/2405.14831 | LLM OpenIE builds a phrase knowledge graph; query concepts seed Personalized PageRank (PPR); passages ranked by accumulated PPR mass. Single-step retrieval. | Multi-hop QA up to 20% over SOTA; matches iterative IRCoT while 10 to 30x cheaper and 6 to 13x faster (abstract). |
| 2 | HippoRAG 2: From RAG to Memory (Gutiérrez, Shu, Qi, Zhou, Su; ICML 2025) | https://arxiv.org/abs/2502.14802 | Adds passage nodes to the graph ("contains" edges), seeds PPR from query-to-triple embedding matches filtered by an LLM ("recognition memory"), PPR damping 0.5, passage-node reset weight 0.05. | +7% on associative memory vs best embedding model (abstract). F1 (HTML Table 2): MuSiQue 48.6 vs 45.7 NV-Embed-v2; HotpotQA 75.5 vs 75.3; NQ 63.3 vs 61.9; 2Wiki 71.0 vs 71.8 HippoRAG v1. Removing passage nodes drops recall@5 from 87.1 to 81.0. |
| 3 | LightRAG (Guo, Xia, Yu, Ao, Huang; EMNLP Findings 2025) | https://arxiv.org/abs/2410.05779 | LLM extracts entity and relation nodes with text profiles; query keywords split into low-level (entity) and high-level (relation) keys; vector match then one-hop neighbourhood expansion; incremental graph union. | Win rates 57.2 to 84.8% vs NaiveRAG on 4 domains; retrieval under 100 tokens vs 610k for GraphRAG (HTML). No accuracy metric reported. |
| 4 | PathRAG (Chen et al.; AAAI 2025) | https://arxiv.org/abs/2502.14902 | Keyword hits become graph nodes; flow-based pruning propagates a resource of 1.0 from each hit with decay α=0.7 per hop split over neighbours, prunes below threshold θ; path reliability = mean node resource; paths ordered ascending so the strongest ends the prompt. | Avg win rate 57.09% vs LightRAG and 59.93% vs GraphRAG over 6 datasets and 5 dimensions; 13.69% fewer prompt tokens than LightRAG (HTML). |
| 5 | From Local to Global: Microsoft GraphRAG (Edge et al.; 2024) | https://arxiv.org/abs/2404.16130 | LLM-built entity graph plus pre-summarised Leiden communities for corpus-level "sensemaking" queries. | Better comprehensiveness and diversity than vector RAG on ~1M-token corpora (abstract, qualitative). |
| 6 | LazyGraphRAG (Microsoft Research blog; Nov 2024) | https://www.microsoft.com/en-us/research/blog/lazygraphrag-setting-a-new-standard-for-quality-and-cost/ | NLP noun-phrase co-occurrence graph plus community detection at index time; all LLM work deferred to query time; best-first ranking of chunks then breadth-first LLM relevance tests over communities under a "relevance test budget". | Indexing cost 0.1% of full GraphRAG (same as vector RAG); more than 700x lower query cost than GraphRAG global search; beats all baselines on local and global queries at 4% of global-search query cost (blog). |
| 7 | KAG: Knowledge Augmented Generation (Liang et al.; WWW 2025) | https://arxiv.org/abs/2409.13731 | Logical-form-guided hybrid reasoning over an OpenSPG graph with mutual indexing between graph and chunks. | Relative F1 +19.6% on 2Wiki and +33.5% on HotpotQA vs existing RAG (search excerpt of abstract; unverified). |
| 8 | LinearRAG (Zhuang et al.; Oct 2025) | https://arxiv.org/abs/2510.10114 | Relation-free "Tri-Graph" (entities, sentences, passages) from lightweight entity extraction; stage 1 entity activation by propagation over the mention matrix; stage 2 PPR over the passage-entity bipartite graph with passage prior = λ·sim + ln(1+entity contributions). Zero LLM tokens at index time. | GPT-Acc HotpotQA 66.5 vs HippoRAG2 64.3 vs vanilla RAG 58.6; 2Wiki 63.7 vs 55.0 vs 43.0; MuSiQue 37.0 vs 35.0 vs 29.6. Indexing 250 s / 0 tokens vs HippoRAG2 1147 s / 6.2M tokens vs LightRAG 4933 s / 86.7M tokens; retrieval 0.093 s vs 1.694 s vs 10.963 s (HTML). |
| 9 | E²GraphRAG (Zhao et al.; May 2025) | https://arxiv.org/abs/2505.24226 | SpaCy entity graph plus LLM summary tree; bidirectional entity-chunk index; adaptive local/global mode chosen from graph structure. | 10x faster indexing than GraphRAG, 100x faster retrieval than LightRAG, competitive QA (abstract). |
| 10 | Hierarchical Lexical Graph (Ghassel et al.; Jun 2025) | https://arxiv.org/abs/2506.08074 | Three tiers: atomic propositions traced to source, topic clusters, entity-relation links; StatementGraphRAG entity-aware beam search for factoids, TopicGraphRAG topic-first for exploratory queries. | Avg relative +23.1% in retrieval recall and correctness over chunk RAG on 5 datasets (abstract). |
| 11 | GraphRAG-Bench: When to use Graphs in RAG (Xiang et al.; ICLR 2026) | https://arxiv.org/abs/2506.05690 | Benchmark spanning fact retrieval, complex reasoning, contextual summarisation, creative generation, with full-pipeline cost accounting. | Fact retrieval: vanilla RAG 60.92 vs HippoRAG2 60.14. Complex reasoning: HippoRAG2 53.38 vs RAG 42.93. Contextual summarisation: 64.10 vs 51.30. Evidence recall on reasoning: HippoRAG 87.91 vs RAG 64.47. Per-query tokens: MS-GraphRAG ~331k, LightRAG ~100k, HippoRAG2 ~1k, RAG ~900 (HTML). "13.4% lower accuracy on NQ" for GraphRAG appears only in a search excerpt; unverified. |
| 12 | Do We Still Need GraphRAG? (Fan, Xue, Liu, Tan; Apr 2026) | https://arxiv.org/abs/2604.09666 | RAGSearch benchmark comparing dense RAG and GraphRAG under multi-round agentic search with fixed backbones and budgets. | Agentic search substantially improves dense RAG and narrows the gap; GraphRAG still ahead on complex multi-hop and more stable once offline cost is amortised; dense RAG competitive or better on general QA (abstract, no numbers). |
| 13 | Is GraphRAG Needed? (Chen et al.; GEM workshop 2026) | https://arxiv.org/abs/2606.25656 | Nine standardised RAG scenarios on semi-structured knowledge bases; context-engineering for graph and agentic RAG. | 19 to 53% token reduction from context engineering; identifies a "retrieval-generation gap": expanded retrieval does not proportionally improve generation, so retrieval metrics overstate advanced retrieval (abstract). |
| 14 | GraphER (Miao et al.; Mar 2026) | https://arxiv.org/abs/2603.24925 | Query-time graph built from data-organisation proximity (structure beyond semantic similarity); graph ranking reranks the base retriever's output; retriever-agnostic, no graph infrastructure. | Gains on table, multi-hop and long-document benchmarks with "minimal query-time latency" (abstract, no numbers). |
| 15 | EviReform (Xu, Li; Aug 2026) | https://arxiv.org/abs/2608.13006 | Retrieved passages formulate residual queries for the unresolved need; original and residual signals normalised separately, combined, propagated between propositions that share entities. | Recall@5 up to +5.59 and F1 up to +4.50 over strongest baseline on 2Wiki, HotpotQA, MuSiQue (abstract). |
| 16 | RAPTOR (Sarthi et al.; ICLR 2024) | https://arxiv.org/abs/2401.18059 | Recursive embed, cluster, summarise into a tree; retrieve at any abstraction level. | +20 points absolute accuracy on QuALITY with GPT-4 vs previous best (abstract). |
| 17 | Dense X Retrieval (Chen et al.; 2023/2024) | https://arxiv.org/abs/2312.06648 | Index atomic propositions instead of passages or sentences. | Contriever avg R@5 43.0 (passage) / 47.3 (sentence) / 52.7 (proposition); R@20 62.8 / 66.1 / 70.5. GTR R@5 65.2 / 66.7 / 68.0. EM@100 words Contriever 14.0 / 17.6 / 21.8 (HTML). |
| 18 | Contextual Retrieval (Anthropic engineering blog; Sep 2024) | https://www.anthropic.com/engineering/contextual-retrieval | Prepend an LLM-written situating sentence to each chunk before embedding and before BM25 indexing ("Contextual BM25"). | Top-20 retrieval failure rate 5.7% to 3.7% (contextual embeddings, -35%), to 2.9% with contextual BM25 (-49%), to 1.9% with reranking (-67%); one-time cost $1.02 per million document tokens (blog). |
| 19 | Late Chunking (Günther, Mohr, Wang, Xiao; Jina, 2024, v3 Jul 2025) | https://arxiv.org/abs/2409.04701 | Embed the whole document, then pool per chunk so chunk vectors carry document context. | Superior results across retrieval tasks without training (abstract, no numbers). Requires a long-context embedder. |
| 20 | Self-RAG (Asai et al.; ICLR 2024) | https://arxiv.org/abs/2310.11511 | Reflection tokens let the model decide when to retrieve and critique its own output. | Significantly outperforms ChatGPT and retrieval-augmented Llama2-chat on open-domain QA, reasoning, fact verification (abstract, no numbers). |
| 21 | Corrective RAG, CRAG (Yan, Gu, Zhu, Ling; 2024) | https://arxiv.org/abs/2401.15884 | Lightweight evaluator grades retrieved docs Correct / Ambiguous / Incorrect; web-search fallback; decompose-then-recompose filtering. | "Significantly improves" RAG on 4 datasets (abstract, no numbers). |
| 22 | Adaptive-RAG (Jeong et al.; NAACL 2024) | https://arxiv.org/abs/2403.14403 | Small classifier predicts query complexity and routes to no-retrieval, single-step, or iterative retrieval. | Better overall efficiency and accuracy than adaptive baselines (abstract, no numbers). |
| 23 | Search-R1 (Jin et al.; 2025) | https://arxiv.org/abs/2503.09516 | RL-trained interleaved reasoning and search-engine calls with retrieved-token masking. | +41% (Qwen2.5-7B) and +20% (3B) over RAG baselines on 7 QA sets (search excerpt; a later version reports +26 / +21 / +10; unverified). |
| 24 | When Iterative RAG Beats Ideal Evidence (Astaraki et al.; Jan 2026) | https://arxiv.org/abs/2601.19827 | Diagnostic study: 11 LLMs under no-context, gold-context, and iterative retrieve-reason loops. | Iterative RAG beats gold-context by up to 25.6 percentage points on ChemKGMultiHopQA; staged retrieval reduces late reasoning failures and context overload (abstract). |
| 25 | IterKey (Hayashi, Kamigaito, Kouda, Watanabe; 2025) | https://arxiv.org/abs/2505.08450 | LLM generates BM25 keywords, retrieves, answers, validates; on failure regenerates keywords. Sparse only, fully interpretable. | 5 to 20% accuracy over BM25-based RAG on 4 QA tasks; comparable to dense-retrieval RAG and prior iterative refinement (abstract). |
| 26 | LogicalRAG: Rethinking Agentic RAG (Zeng et al.; May 2026) | https://arxiv.org/abs/2605.27123 | Agent expresses retrieval intent as logical expressions (required terms, alternatives, exclusions) executed on an inverted index; no embeddings. | Matches strong agentic hybrid baselines with substantially lower construction and serving cost and fewer hallucinations (abstract, no numbers). |
| 27 | Query Decomposition for RAG: Balancing Exploration-Exploitation (Petcu et al.; Oct 2025) | https://arxiv.org/abs/2510.18633 | Treat sub-queries as bandit arms; sequentially allocate retrieval budget to the most informative sub-query. | +35% document-level precision, +15% α-nDCG, better long-form generation (abstract). |
| 28 | DMQR-RAG (Li et al.; Nov 2024) | https://arxiv.org/abs/2411.13154 | Four multi-query rewriting strategies at different information levels with adaptive selection of how many rewrites to use. | Multi-query rewriting beats single rewriting and vanilla RAG-Fusion; validated in academic and industry settings (search excerpt; no numbers on abstract page). |
| 29 | RAG-Fusion (Rackauckas; 2024) | https://arxiv.org/abs/2402.03367 | Generate several queries from the user query, retrieve for each, fuse with reciprocal rank fusion. | Qualitative: more comprehensive answers; off-topic answers when generated queries drift from the original (abstract). |
| 30 | Scaling RAG with RAG Fusion: Industry Deployment (Medrano, Verma, Chhabra; Mar 2026) | https://arxiv.org/abs/2603.02153 | Production evaluation of multi-query retrieval plus RRF against an enterprise knowledge base. | Hit@10 fell 0.51 to 0.48 in several fusion configurations; recall gains "largely neutralized after re-ranking and truncation"; extra latency (abstract). |
| 31 | From BM25 to Corrective RAG (Akarsu, Karaman, Mierbach; Apr 2026) | https://arxiv.org/abs/2604.01733 | Benchmark of 10 retrieval strategies on 23,088 financial text-and-table queries over 7,318 documents. | Hybrid plus neural reranker Recall@5 0.816, MRR@3 0.605; BM25 outperforms text-embedding-3-large on this domain; HyDE and multi-query gave limited benefit on numeric queries; contextual retrieval gave consistent gains (abstract). |
| 32 | RAGSmith (Kartal et al.; Nov 2025) | https://arxiv.org/abs/2511.01386 | Genetic search over 46,080 RAG pipeline configurations across 9 technique families, 6 domains. | +3.8% average over vanilla RAG (range +1.2 to +6.9); up to +12.5% retrieval and +7.5% generation; query expansion, reranking, augmentation are domain-dependent; passage compression never selected (abstract). |
| 33 | Zep: Temporal Knowledge Graph for Agent Memory (Rasmussen et al.; Jan 2025) | https://arxiv.org/abs/2501.13956 | Graphiti bi-temporal knowledge graph with fact validity intervals; non-lossy updates. | DMR 94.8% vs MemGPT 93.4%; LongMemEval up to +18.5% accuracy with 90% lower latency (abstract). Retrieval internals (cosine, BM25, BFS, RRF, MMR, node-distance rerankers) are from recollection of the PDF, which returned 404 today; unverified. |
| 34 | A-MEM: Agentic Memory (Xu et al.; NeurIPS 2025) | https://arxiv.org/abs/2502.12110 | Zettelkasten-style notes with LLM-generated context, keywords, tags; LLM-decided links to prior notes; "memory evolution" updates older notes. | Superior to SOTA baselines across 6 foundation models; large token reduction via top-k retrieval (abstract, no numbers). |
| 35 | Mem0 (Chhikara et al.; Apr 2025) | https://arxiv.org/abs/2504.19413 | Extract, consolidate, and retrieve salient facts from conversations; Mem0g graph variant. | +26% relative LLM-as-judge over OpenAI memory on LOCOMO; 91% lower p95 latency and >90% token saving vs full context; graph variant about +2% over base (abstract). |
| 36 | SmartSearch: Ranking Beats Structure (Derehag, Calva, Ghiurau; Mar 2026) | https://arxiv.org/abs/2603.15599 | No LLM structuring at ingest: NER-weighted substring matching for recall, rule-based entity discovery for multi-hop expansion, CrossEncoder+ColBERT rank fusion on CPU (~650 ms), score-adaptive truncation. | LoCoMo 93.5%, LongMemEval-S 88.4%; oracle recall 98.6% but only 22.5% of gold evidence survives naive truncation; 8.5x fewer tokens than full context (abstract). |
| 37 | Engram: Bi-Temporal Memory Engine (Wang; Jun 2026) | https://arxiv.org/abs/2606.09900 | Lossless episode append with no LLM on the write path; async atomic fact extraction; invalidate-never-delete; hybrid read path fusing dense, lexical, graph and recency with point-in-time filtering. | LongMemEval_S 83.6% vs 73.2% full context (+10.4 pp, p < 1e-6); ~9.6k retrieved tokens vs 79k (abstract). |
| 38 | Chain-of-Memory (Xu et al.; Jan 2026) | https://arxiv.org/abs/2601.14287 | Lightweight memory construction paired with heavy utilisation: organise retrieved fragments into inference chains with dynamic evolution and adaptive truncation. | +7.5 to 10.4% accuracy; about 2.7% of the token consumption and 6.0% of the latency of complex graph-memory systems (abstract). |
| 39 | Learning What to Remember (Chen, Cheng; Jun 2026) | https://arxiv.org/abs/2606.12945 | Seven-factor learned memory value model (emotional intensity, goal relevance, value alignment, self/user relevance, task utility, reliability, usage history). | Gold-evidence retention 0.770 (learned) vs 0.657 (uniform) vs 0.518 (best single factor) vs 0.368 (recency-only) on 479 cases (abstract). |
| 40 | PersonalAI (Menschikov et al.; 2025, v2 Apr 2026) | https://arxiv.org/abs/2506.17001 | AriGraph-style KG with hyper-edges for personal history; A*, WaterCircles, beam search and hybrid traversals. | HotpotQA EM 60.0 (GPT-4o-mini) vs 36.1 to 45.9 for other GraphRAG methods; best traversal depends on model size (HTML). |
| 41 | GAM: Hierarchical Graph-based Agentic Memory (Wu et al.; Apr 2026) | https://arxiv.org/abs/2604.12285 | Event-progression graph for live dialogue plus topic associative network for consolidation; graph-guided multi-factor retrieval. | Better accuracy and efficiency on LoCoMo and LongDialQA (abstract, no numbers). |
| 42 | Agentic RAG: A Survey (Singh, Ehtesham, Kumar, Khoei; 2025, v4 Apr 2026) | https://arxiv.org/abs/2501.09136 | Taxonomy of reflection, planning, tool-use, and multi-agent RAG patterns. | Survey, no numbers. |

Papers noted but not central because they require an embedding model or trained retriever: HyDE (https://arxiv.org/abs/2212.10496), ColBERT late interaction (https://arxiv.org/abs/2004.12832) and jina-reranker-v3 (https://arxiv.org/abs/2509.25085), CSPLADE learned sparse (https://arxiv.org/abs/2504.10816), Latent Terms BM25-ready vocabularies from dense models (https://arxiv.org/abs/2605.29384), RankRAG (https://arxiv.org/abs/2407.02485), MemoRAG (https://arxiv.org/abs/2409.05591), G-RAG GNN reranker (https://arxiv.org/abs/2405.18414), GFM-RAG (https://arxiv.org/abs/2502.01113).

---

## 2. Ranked shortlist for a SQLite FTS5 note store with tags, links, notebooks and an agent `search` tool

Ranking weighs evidence strength, expected gain without embeddings, and implementation cost. Gains are estimates; the cited numbers were measured on different corpora and retrievers.

### 2.1 Contextual chunk headers on the indexed text (rank 1)

Mechanism. Prepend to every indexed row the note title, notebook name, full tag path with class (for example `class:project/parent/child`), parent note title, and the titles of linked notes. Optionally add a one-sentence LLM-written situating line per note at save time, as in Anthropic's prompt.

Evidence. Anthropic contextual BM25 combined with contextual embeddings cut top-20 failure rate from 5.7% to 2.9%; the BM25-to-CRAG 2026 benchmark reports "consistent gains" from contextual retrieval and shows BM25 beating a strong dense model on precise domain vocabulary. The deterministic heading-breadcrumb variant needs no LLM call and is widely used in practice.

Estimated gain. Moderate to large on short notes whose bodies lack the words users search for, and on notes whose meaning depends on their notebook or tag. Largest single lever available without embeddings.

Cost. Low. One extra FTS column (or a header prefix in the existing column) plus a reindex. Use FTS5 `bm25(col_weights...)` to weight the header column above the body.

### 2.2 Agent-driven multi-query keyword expansion fused with reciprocal rank fusion (rank 2)

Mechanism. The agent already calls `search`. Let it issue 3 to 5 lexical queries per turn: original query, synonyms, decomposed sub-questions, entity names, tag names. Fuse the ranked lists with RRF (k around 30 to 60). Expose FTS5 boolean operators (AND, OR, NOT, NEAR, prefix) so the agent can express required and excluded terms, as LogicalRAG does.

Evidence. IterKey: 5 to 20% over BM25 RAG using BM25 only. LogicalRAG: matches agentic hybrid baselines on an inverted index alone. Query decomposition with budget allocation: +35% precision, +15% α-nDCG. EviReform residual queries: up to +5.59 R@5. Counter-evidence: the 2026 industry RAG Fusion deployment lost Hit@10 (0.51 to 0.48) once results were truncated, and RAG-Fusion reports off-topic answers when generated queries drift. RAGSmith finds query expansion domain-dependent.

Estimated gain. Moderate on recall, especially for vocabulary mismatch and multi-part questions. Must keep the original query's list weighted highest and cap the number of rewrites to avoid drift.

Cost. Low. Prompt change plus a fusion function and a small extension of the `search` tool schema.

### 2.3 Reciprocal rank fusion across several cheap retrievers (rank 3)

Mechanism. Fuse ranked lists from: title FTS, body FTS, exact tag-name match, notebook-scoped FTS, one-hop link neighbourhood of the top hits, and a recency list. RRF needs no score calibration, which matters because FTS5 bm25 scores on trigrams are not comparable across columns.

Evidence. Every 2025 to 2026 hybrid study surveyed uses RRF as the default fusion because it is robust without score normalisation; SmartSearch reaches 93.5% on LoCoMo with rule-based lexical recall and rank fusion only; "Learning What to Remember" shows a multi-factor score beats any single factor (0.770 vs 0.518).

Estimated gain. Moderate, mostly in robustness: fewer total misses rather than higher top-1 precision.

Cost. Low. Several SQL queries and a fusion step in the search service.

### 2.4 Personalized PageRank over the note, tag and link graph seeded by lexical hits (rank 4)

Mechanism. Build an in-memory graph with note nodes, tag nodes (tag-tree edges parent to child), notebook nodes, and explicit note-to-note link edges. Seed with FTS hits weighted by rank, run PPR (damping about 0.5 as in HippoRAG 2, 15 to 30 power iterations), then fuse the PPR ranking with the direct FTS list by RRF so that direct hits are never displaced. This mirrors LinearRAG, which runs PPR over a passage-entity bipartite graph with zero LLM tokens at index time; here tags and links replace extracted entities.

Evidence for gain. HippoRAG 2 MuSiQue F1 48.6 vs 45.7; LinearRAG 2Wiki 63.7 vs 43.0 vanilla and HotpotQA 66.5 vs 58.6; GraphRAG-Bench complex reasoning 53.38 vs 42.93 and evidence recall 87.91 vs 64.47.

Evidence for risk. On simple fact lookup GraphRAG-Bench shows no gain (60.14 vs 60.92); HippoRAG 2 needed passage nodes to stop recall@5 falling from 87.1 to 81.0. Search excerpts note PPR's hub bias, which in a tag graph means broad tags dominate. Mitigations: normalise tag-node transition weight by degree, cap fan-out per tag class, or exclude tags above a fan-out threshold.

Estimated gain. Meaningful on associative and multi-hop questions ("what did I note that relates to X and Y"); neutral on direct lookups when fused with direct hits.

Cost. Medium. Graph load and sparse PPR; a few thousand notes fit in memory and 20 iterations take milliseconds. Needs cache invalidation when links or tags change.

### 2.5 Corrective and adaptive retrieval loop driven by the agent (rank 5)

Mechanism. After a search, the agent grades whether results answer the question (CRAG-style), then answers, reformulates keywords (IterKey-style), or widens to link neighbours, notebook siblings, and parent or child tags. Add an Adaptive-RAG style router in the prompt: single search for simple lookups, loop only when the first result set is graded insufficient, hard cap on iterations.

Evidence. Iterative RAG beat gold context by up to 25.6 pp; "Do We Still Need GraphRAG" finds agentic search closes much of the gap to graph methods for dense RAG; Search-R1 gains are large but come from RL training, which is not available here; CRAG and Adaptive-RAG abstracts report gains without numbers.

Estimated gain. Moderate on hard questions; near zero on simple ones, where the router should stop after one search.

Cost. Low in code, medium in latency and tokens per query.

### 2.6 Temporal recency and validity as one fusion signal (rank 6)

Mechanism. Add an exponential recency term on `updated_at` as one RRF list. For memory-style notes keep `valid_from` and `invalid_at` fields so superseded facts are filtered at query time rather than deleted (Zep and Engram bi-temporal pattern).

Evidence. Zep up to +18.5% on LongMemEval with a bi-temporal graph; Engram 83.6% vs 73.2% with a recency-aware hybrid read path; recency alone scores 0.368 vs 0.770 for a multi-factor model, so recency must stay a minor signal.

Estimated gain. Small on retrieval quality overall, larger for "what is the current value of X" questions and for suppressing stale notes.

Cost. Low. Two nullable columns and one extra ranked list.

### 2.7 Section-level indexing with parent-note aggregation, plus notebook or tag summaries (rank 7)

Mechanism. Index headings or paragraphs as FTS rows that carry the contextual header from 2.1; aggregate hits to the parent note by max or sum of RRF scores (small-to-big). Use the existing notebook and tag hierarchy as the RAPTOR-style tree and index an LLM summary per notebook or tag node as an ordinary row, so "global" questions hit a summary and drill down.

Evidence. Dense X: finer units raise R@5 by 9.7 points for Contriever and 2.8 for GTR; the effect with BM25 is not reported and is probably smaller because bm25 already length-normalises. RAPTOR +20 points on QuALITY, but its clustering needs embeddings, which the tag tree replaces. Hierarchical Lexical Graph +23.1% relative with proposition tiers.

Estimated gain. Small to moderate for long notes; helps precision of the passage shown to the agent more than note-level recall.

Cost. Medium. Schema change, chunker, reindex, and an aggregation step.

### 2.8 LightRAG and PathRAG style node and edge scoring (rank 8)

Mechanism. LightRAG's entity and relation profiles require LLM extraction at index time (86.7M tokens on LinearRAG's corpus) and vector matching of keywords, so the full method does not fit. PathRAG's flow-based pruning (decay α=0.7, threshold, path reliability, ascending path order in the prompt) can be reused directly on the note link graph to select and order the link paths between two lexical hit notes for the agent's context.

Evidence. PathRAG win rates 57 to 60% are LLM-judged quality dimensions, not accuracy; LightRAG reports no accuracy metric; E²GraphRAG and LinearRAG both replace LLM graph extraction with cheap NLP or entity linking and stay competitive.

Estimated gain. Uncertain; useful mainly for "how are X and Y connected" questions and for ordering context.

Cost. Medium for path pruning on the existing link graph; high if entity extraction is added.

---

## 3. Pitfalls reported in the papers

- **Graphs regress on simple queries.** GraphRAG-Bench (ICLR 2026): vanilla RAG matches or beats GraphRAG on fact retrieval and graphs "introduce redundant or noisy information" on simpler queries; time-sensitive queries are called out as weak. Always fuse graph output with direct lexical hits instead of replacing them.
- **Indexing and query cost.** MS-GraphRAG global search used about 331k tokens per query and LightRAG about 100k in GraphRAG-Bench; LightRAG indexing consumed 86.7M tokens and 4933 s versus 0 tokens and 250 s for LinearRAG. LazyGraphRAG exists because full GraphRAG indexing is about 1000x more expensive than vector indexing.
- **Fusion gains vanish after truncation.** The 2026 industry RAG Fusion study found higher raw recall but lower Hit@10 after reranking and cut-off. SmartSearch reports 98.6% oracle recall but only 22.5% of gold evidence surviving naive token-budget truncation. Ranking and budget-aware truncation matter more than adding retrievers.
- **Generated queries drift.** RAG-Fusion reports off-topic answers when rewritten queries lose the original intent; the BM25-to-CRAG benchmark found HyDE and multi-query gave little benefit for precise numeric queries; RAGSmith finds query expansion is domain-dependent.
- **Retrieval-generation gap.** "Is GraphRAG Needed?" finds expanded retrieval does not raise answer quality proportionally and that retrieval metrics overstate advanced retrieval benefits. RAGSmith found only +3.8% average end-to-end gain from full-pipeline optimisation and never selected passage compression.
- **Heavy structuring at ingest is often wasted.** SmartSearch and Chain-of-Memory both argue LLM-based memory structuring costs far more than it returns; Chain-of-Memory reaches +7.5 to 10.4% at 2.7% of the tokens. Mem0's graph variant added only about 2% over its base.
- **PPR hub bias.** PPR favours high-degree nodes regardless of query relevance; in a tag graph, broad tags are hubs. HippoRAG 2's fixes were LLM-filtered seed triples and a small passage-node weight (0.05).
- **Recency alone is a poor ranker.** 0.368 gold-evidence retention versus 0.770 for a learned multi-factor score; recency should be one signal among several.
- **Implementation note (not from the papers).** FTS5 trigram bm25 scores are computed over trigram tokens, so tokens shorter than three characters never match and term weighting differs from word-level BM25. Column weights in `bm25()` and a separate word-tokenised title or header column would let the contextual header carry more weight than the body.

Unverified items to double-check before quoting externally: the KAG relative F1 numbers, the Search-R1 percentages, the "13.4% lower on NQ" GraphRAG-Bench claim, and the Zep retrieval-mechanism details, all of which were seen only in search excerpts or from memory.

---

## Sources

- https://arxiv.org/abs/2405.14831 (HippoRAG)
- https://arxiv.org/abs/2502.14802 and https://arxiv.org/html/2502.14802 (HippoRAG 2)
- https://arxiv.org/abs/2410.05779 and https://arxiv.org/html/2410.05779 (LightRAG)
- https://arxiv.org/abs/2502.14902 and https://arxiv.org/html/2502.14902 (PathRAG)
- https://arxiv.org/abs/2404.16130 (Microsoft GraphRAG)
- https://www.microsoft.com/en-us/research/blog/lazygraphrag-setting-a-new-standard-for-quality-and-cost/ (LazyGraphRAG)
- https://arxiv.org/abs/2409.13731 (KAG)
- https://arxiv.org/abs/2510.10114 and https://arxiv.org/html/2510.10114v1 (LinearRAG)
- https://arxiv.org/abs/2505.24226 (E²GraphRAG)
- https://arxiv.org/abs/2506.08074 (Hierarchical Lexical Graph)
- https://arxiv.org/abs/2506.05690 and https://arxiv.org/html/2506.05690 (GraphRAG-Bench)
- https://arxiv.org/abs/2604.09666 (Do We Still Need GraphRAG?)
- https://arxiv.org/abs/2606.25656 (Is GraphRAG Needed?)
- https://arxiv.org/abs/2603.24925 (GraphER)
- https://arxiv.org/abs/2608.13006 (EviReform)
- https://arxiv.org/abs/2401.18059 (RAPTOR)
- https://arxiv.org/abs/2312.06648 and https://arxiv.org/html/2312.06648v2 (Dense X Retrieval)
- https://www.anthropic.com/engineering/contextual-retrieval (Contextual Retrieval)
- https://arxiv.org/abs/2409.04701 (Late Chunking)
- https://arxiv.org/abs/2310.11511 (Self-RAG)
- https://arxiv.org/abs/2401.15884 (CRAG)
- https://arxiv.org/abs/2403.14403 (Adaptive-RAG)
- https://arxiv.org/abs/2503.09516 (Search-R1)
- https://arxiv.org/abs/2601.19827 (When Iterative RAG Beats Ideal Evidence)
- https://arxiv.org/abs/2505.08450 (IterKey)
- https://arxiv.org/abs/2605.27123 (LogicalRAG)
- https://arxiv.org/abs/2510.18633 (Query Decomposition for RAG)
- https://arxiv.org/abs/2411.13154 (DMQR-RAG)
- https://arxiv.org/abs/2402.03367 (RAG-Fusion)
- https://arxiv.org/abs/2603.02153 (RAG Fusion industry deployment)
- https://arxiv.org/abs/2604.01733 (From BM25 to Corrective RAG)
- https://arxiv.org/abs/2511.01386 (RAGSmith)
- https://arxiv.org/abs/2501.13956 (Zep)
- https://arxiv.org/abs/2502.12110 (A-MEM)
- https://arxiv.org/abs/2504.19413 (Mem0)
- https://arxiv.org/abs/2603.15599 (SmartSearch)
- https://arxiv.org/abs/2606.09900 (Engram bi-temporal memory)
- https://arxiv.org/abs/2601.14287 (Chain-of-Memory)
- https://arxiv.org/abs/2606.12945 (Learning What to Remember)
- https://arxiv.org/abs/2506.17001 and https://arxiv.org/html/2506.17001 (PersonalAI)
- https://arxiv.org/abs/2604.12285 (GAM)
- https://arxiv.org/abs/2501.09136 (Agentic RAG survey)
- https://arxiv.org/abs/2212.10496 (HyDE)
- https://arxiv.org/abs/2004.12832 (ColBERT)
- https://arxiv.org/abs/2509.25085 (jina-reranker-v3)
- https://arxiv.org/abs/2504.10816 (CSPLADE)
- https://arxiv.org/abs/2605.29384 (Latent Terms)
- https://arxiv.org/abs/2407.02485 (RankRAG)
- https://arxiv.org/abs/2409.05591 (MemoRAG)
- https://arxiv.org/abs/2405.18414 (G-RAG)
- https://arxiv.org/abs/2502.01113 (GFM-RAG)
- https://arxiv.org/abs/2506.22141 (DAPFAM, RRF k=30 note, search excerpt only)
