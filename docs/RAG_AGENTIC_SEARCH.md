# RAG Agentic Search — Documentação de Uso

**Data:** 2026-05-05
**Versão:** 1.0

---

## 1. Visão Geral

O sistema de busca RAG do Ratio oferece dois modos de recuperação e síntese:

- **Modo `standard`**: Busca em duas rodadas (expansão conceitual → expansão ancorada), com reranking e síntese única.
- **Modo `agentic`**: Busca agêntica com FSM (Finite State Machine) que planeja, recupera, avalia cobertura, expande seletivamente e sintetiza — respeitando orçamento máximo de etapas, consultas e tempo.

Ambos os modos compartilham a infraestrutura de:
- Embedding com provedor configurável (padrão: LM Studio / EmbeddingGemma 300M, 768 dimensoes)
- Busca híbrida em LanceDB (vetor + FTS via RRF)
- Reranking (Local ou MiniMax M2.7)
- Geração com MiniMax M2.7-highspeed (padrão) ou outro provedor configurado
- Proteção anti-CJK para modelos MiniMax

---

## 2. Diferença entre Consulta Padrão e Consulta Agêntica

### Modo `standard`

```
Pergunta → plan_query() → subconsultas conceituais (round 1)
  → busca → agregação → extração de entidades
  → subconsultas específicas ancoradas (round 2, se entidades extraídas)
  → rerank → síntese → resposta
```

**Características:**
- Duas rodadas de busca no máximo
- Até 5 subconsultas iniciais + até 3 de follow-up
- Sem loop de reavaliação de cobertura
- Síntese executada uma única vez ao final

### Modo `agentic`

```
INIT → PLAN → SEARCH (round 1) → EVALUATE_EVIDENCE
  → EXPAND_OR_STOP (lacunas por tribunal/faceta, depois entidades)
  → SYNTHESIZE → VERIFY_ANSWER → FINAL
```

**Características:**
- Loop agêntico com avaliação de cobertura a cada iteração
- Até `max_steps` iterações (padrão: 6)
- Até `max_queries` consultas totais (padrão: 8)
- Timeout configurável (padrão: 45s)
- Cobertura por tribunal solicitado: quando a pergunta menciona tribunais específicos (ex.: TJSP e TJMT), esse escopo textual prevalece sobre filtros mais amplos selecionados na UI, e documentos de tribunais não solicitados são retirados do contexto final
- Reconsulta direcionada: se a primeira rodada não trouxer documentos de algum tribunal solicitado, o agente executa novas buscas com `filters.tribunais = ["<TRIBUNAL>"]` para cada tribunal faltante, respeitando `max_queries`, `max_steps` e timeout
- Planejamento por facetas de pesquisa: perguntas complexas são decompostas em dimensões como tribunal, sujeito passivo, tese jurídica, resultado, ranking quantitativo e tema legal
- Reconsulta por lacuna temática: se uma faceta obrigatória continuar sem evidência, o agente gera novas consultas de banco com palavras-chave jurídicas e filtros estruturados, antes de cair na expansão ancorada por entidades
- Reconsulta por amostra pequena: se as facetas obrigatórias estiverem cobertas, mas o número de documentos relevantes estiver abaixo do alvo mínimo recomendado para a pergunta, o agente varia termos jurídicos e executa novas buscas antes de parar
- Verificação de extrapolação de evidências na resposta final
- Trace operacional exposto ao cliente quando `include_trace=true`

---

## 3. Como a Expansão Progressiva Ancorada em Evidências Funciona

### Fase 1 — Subconsultas Conceituais (Round 1)

O `QueryPlan` analisa a pergunta do usuário e gera 2–6 subconsultas amplas que representam os aspectos conceituais da pergunta. **Nenhuma entidade específica (número de processo, súmula, tema) é inventada nesta fase.**

Para pedidos analíticos, o planner separa a tarefa analítica da recuperação de evidências. Termos como `ranking`, `perfil`, `calcule`, `incidência`, `linha do tempo` e `tendência` orientam o tipo de resposta, mas não devem ser enviados ao banco como se fossem palavras-chave jurisprudenciais. As subconsultas devem buscar os julgados que permitam produzir a análise: instituto jurídico, artigo legal, sujeito/recorte fático, classe processual, resultado decisório, tribunal e sinônimos úteis. Exemplo: um pedido de ranking por deferimento gera consultas por `art. 139 IV CPC`, `medidas executivas atípicas`, `deferimento`, `indeferimento`, `sócio controlador` e tribunal, não uma busca por `ranking de órgãos julgadores`.

Exemplo para "STF mudou entendimento sobre prisão em segunda instância?":
```
STF prisão segunda instância jurisprudência
STF jurisprudência atual prisão segunda instância
STF mudança entendimento prisão segunda instância
```

### Fase 2 — Facetas de Pesquisa e Reconsultas por Lacuna

Após o `QueryPlan`, o modo agêntico cria um conjunto de `ResearchFacet` para representar o que precisa estar coberto na evidência. Exemplos:

- `court_coverage`: tribunal solicitado ou filtrado.
- `legal_subject`: sujeito passivo ou recorte fático-jurídico, como `sócio controlador`.
- `outcome`: resultado decisório, como deferimento ou indeferimento.
- `quantitative`: dados necessários para rankings, contagens ou taxas, como órgão julgador, relator e resultado.
- `legal_theme`: núcleo jurídico da pergunta, como art. 139, IV, do CPC e medidas executivas atípicas.

A cada rodada, `_evaluate_facet_coverage` marca cada faceta como `satisfied` ou `missing`. Quando há lacunas, `_build_gap_search_actions` emite ações de busca com este contrato:

```json
{
  "facet_id": "subject_controller_partner",
  "query": "sócio controlador art. 139 IV CPC medidas executivas atípicas",
  "filters": {"tribunais": ["TJMT"]},
  "reason_code": "missing_legal_subject",
  "expected_signal": "socio controlador"
}
```

Essas ações obedecem às mesmas restrições do FSM:

- respeitam `max_queries`, `max_steps` e timeout;
- não repetem pares `query + filters` já executados;
- usam filtros unitários quando o escopo por tribunal é explícito e pequeno;
- podem criar palavras-chave e sinônimos jurídicos, mas não inventam números de processo, temas, súmulas ou precedentes específicos;
- descartam do contexto final documentos fora do escopo textual de tribunal quando a pergunta mencionou tribunais específicos.

Metadados de auditoria retornados em `meta`:

- `agentic_research_facets`: facetas extraídas da pergunta.
- `agentic_facet_coverage`: status final por faceta, com documentos que a satisfizeram.
- `agentic_missing_required_facets`: facetas obrigatórias que continuaram sem evidência.
- `agentic_gap_search_actions`: consultas temáticas executadas para cobrir lacunas.
- `agentic_research_plan`: contrato consolidado para UI e histórico, contendo facetas, consultas executadas, reconsultas, alvo mínimo de documentos e sinalização de expansão por baixa evidência.
- `agentic_min_relevant_documents`: alvo mínimo usado para decidir se a amostra recuperada é suficiente. Quando `0`, o sistema calcula um alvo recomendado a partir das facetas.
- `agentic_low_evidence_expansion_used`: `true` quando o loop fez buscas adicionais porque a amostra estava pequena.

Antes da geração final, a mesma auditoria é compactada em uma seção
`[INSTRUCAO DE SINTESE - COBERTURA AGENTICA]` anexada ao contexto documental.
Essa seção instrui a LLM a declarar limitações de cobertura, distinguir ausência
de documentos recuperados de conclusão jurídica ampla e não preencher lacunas com
conhecimento externo.

### Fase 3 — Expansão Ancorada (apenas se aplicável)

Depois das reconsultas por tribunal e por faceta, se a agregação dos resultados revelar entidades extraídas dos metadados dos documentos (números de processo, tribunais, classes processuais), o sistema gera subconsultas específicas ancoradas nessas entidades.

**Regra crítica:** Round 2 só adiciona subconsultas específicas se:
1. `extracted_entities.process_numbers` for não-vazio, OU
2. `extracted_entities.courts` for não-vazio

Isso impede que o sistema invente identificadores jurisprudenciais.

### Fase 4 — Avaliação de Cobertura (Modo Agêntico)

Em modo `agentic`, após cada rodada de busca o sistema avalia:
- `has_relevant_documents`: há documentos recuperados?
- `has_temporal_markers`: há marcadores de mudança temporal ("mudou", "superou", "overruling")?
- `has_comparative_markers`: há marcadores comparativos ("diferente", "distinto")?
- `has_source_diversity`: há mais de um tribunal ou tipo de fonte?
- `has_current_or_latest_marker`: há menção a entendimento atual?
- cobertura dos tribunais-alvo: se `query` mencionar tribunais, eles definem `agentic_target_tribunals`; se não mencionar, o filtro `tribunais` da requisição define o alvo
- cobertura das facetas obrigatórias da pergunta, incluindo sujeito, resultado, ranking e tema jurídico
- suficiência quantitativa mínima: rankings, comparações e perguntas com recortes específicos exigem uma amostra mínima antes de parar; o alvo pode ser configurado por `agentic_min_relevant_documents` ou inferido automaticamente
- `missing`: lista de lacunas detectadas

Se `missing` for vazio, o loop para e a síntese é executada. Caso contrário, o agente tenta primeiro cobrir tribunais faltantes com buscas unitárias filtradas, depois facetas temáticas faltantes com consultas estruturadas, depois amostra insuficiente com consultas semanticamente variadas, e por fim expandir com subconsultas específicas ancoradas.

Metadados de auditoria retornados em `meta`:
- `agentic_target_tribunals`: tribunais efetivamente usados como escopo de cobertura.
- `agentic_question_scoped_tribunals`: `true` quando o escopo veio dos tribunais citados na pergunta, permitindo podar filtros selecionados mas irrelevantes.
- `agentic_missing_requested_tribunals`: tribunais que continuaram sem documentos após as reconsultas permitidas pelo orçamento.
- `agentic_research_facets`, `agentic_facet_coverage`, `agentic_missing_required_facets` e `agentic_gap_search_actions`: auditoria do planejamento por facetas e das reconsultas temáticas.
- `agentic_research_plan`: objeto pronto para renderização no frontend e persistência no histórico da conversa.

---

## 4. Por Que o Sistema Não Deve Usar Memória Livre da LLM para Identificadores Jurídicos

O sistema **não utiliza conhecimento interno da LLM** como fonte de identificadores jurídicos (números de processo, súmulas, temas, relatores, datas de mudança de entendimento). Isso porque:

1. **Alucinação de identificadores**: LLMs podem "lembrar" de casos que não existem ou distorcer detalhes de casos reais.
2. **Falsos positivos**: Um número de processo inventado parece plausível e pode ser aceito como genuíno.
3. **Incompatibilidade com o regime de compliance**: Identificadores jurídicos devem ser rastreáveis a documentos concretos no acervo.
4. **Preservação de auditabilidade**: O trace operacional só é significativo se todas as consultas puderem ser vinculadas a fontes reais.

O `QueryPlan` detecta identificadores **fornecidos pelo usuário** na pergunta e os preserva. Os demais são extraídos exclusivamente dos **metadados dos documentos recuperados**.

---

## 5. Estratégia Anti-CJK para MiniMax/M2.7

### O Problema

O modelo MiniMax/M2.7 pode, em condições de baixa temperatura ou com certos prompts, inserir caracteres CJK (Chinês, Japonês, Coreano) na saída. Em textos jurídicos em português do Brasil, isso indica um problema de geração.

### Detecção (Pré-Geração)

Quando `is_minimax_model(model_id)` retorna `True`, o sistema injeta ao final do system prompt a instrução:

> "Responda exclusivamente em português do Brasil. Não inclua caracteres chineses, japoneses ou coreanos (CJK) em nenhuma parte da resposta."

### Sanitização (Pós-Geração)

Após cada chamada ao modelo MiniMax, antes de retornar a resposta:

1. `contains_cjk(text)` — regex detecta CJK (CJK Unified Ideographs, Extensions A–G, Hiragana, Katakana, Hangul)
2. Se detectado: `sanitize_cjk(text)` — substitui caracteres CJK por espaço simples
3. Warnings `minimax_cjk_detected` e `minimax_cjk_sanitized` são registrados no diagnóstico

### Implementação

```python
# rag/prompts.py
is_minimax_model(model_id)  # case-insensitive, reconhece "minimax", "m2.7", etc.
contains_cjk(text)          # regex CJK_RE
sanitize_cjk(text)          # substituição por espaço

# rag/query.py (pós-geração)
answer, cjk_meta = post_process_minimax_output(answer)
generation_diagnostics["minimax_cjk_detected"] = cjk_meta["minimax_cjk_detected"]
generation_diagnostics["minimax_cjk_sanitized"] = cjk_meta["minimax_cjk_sanitized"]
```

---

## 6. Como Usar Via API

### Endpoint Principal

```
POST /api/query
Content-Type: application/json
```

### Parâmetros Principais

| Campo | Tipo | Padrão | Descrição |
|---|---|---|---|
| `query` | `string` | — | Pergunta do usuário (3–4000 caracteres) |
| `search_mode` | `"standard"` \| `"agentic"` | `"standard"` | Modo de busca |
| `include_search_trace` | `boolean` | `false` | Incluir trace operacional na resposta |
| `agentic_options` | `object` | `null` | Configuração do agente (max_steps, max_queries, etc.) |
| `tribunais` | `array<string>` | `null` | Filtro estruturado de tribunais. Use JSON, por exemplo `["TJSP", "TJMT"]`; não dependa apenas de escrever os tribunais dentro de `query`. |
| `tipos` | `array<string>` | `null` | Filtro estruturado de tipos documentais, por exemplo `["acordao"]`. |

### Parâmetros de Agente (`agentic_options`)

| Campo | Tipo | Padrão | Descrição |
|---|---|---|---|
| `max_steps` | `int` | `6` | Iterações máximas do loop agêntico |
| `max_queries` | `int` | `8` | Consultas totais máximas |
| `max_documents` | `int` | `30` | Documentos máximos no contexto |
| `timeout_seconds` | `int` | `45` | Timeout total em segundos |

---

## 7. Exemplos de Payload

### Payload — Modo `standard`

```json
POST /api/query
{
  "query": "STF mudou entendimento sobre prisão em segunda instância?",
  "search_mode": "standard",
  "include_search_trace": false,
  "tribunais": ["STF"],
  "tipos": ["acordao"],
  "prefer_recent": true
}
```

**Resposta:**
```json
{
  "answer": "Com base nos documentos recuperados...",
  "docs": [...],
  "search_mode": "standard",
  "search_trace": [],
  "warnings": [],
  "meta": {
    "timings": {...},
    "candidates": 80,
    "returned_docs": 11
  }
}
```

### Payload — Modo `agentic` com Trace

```json
POST /api/query
{
  "query": "STF mudou entendimento sobre prisão em segunda instância?",
  "search_mode": "agentic",
  "include_search_trace": true,
  "agentic_options": {
    "max_steps": 3,
    "max_queries": 5,
    "timeout_seconds": 30
  },
  "tribunais": ["STF"],
  "tipos": ["acordao"]
}
```

**Resposta:**
```json
{
  "answer": "Com base nos documentos recuperados...",
  "docs": [...],
  "search_mode": "agentic",
  "search_trace": [
    {"step": 1, "state": "SEARCH", "query": "STF prisão segunda instância jurisprudência", "reason": "round 1 conceptual query", "results_count": 8},
    {"step": 2, "state": "EVALUATE_EVIDENCE", "query": null, "reason": "coverage: has_relevant=True, missing=['temporal markers']", "results_count": 0},
    {"step": 3, "state": "SEARCH", "query": "STF HC prisão segunda instância", "reason": "round 2 anchored specific query", "results_count": 3},
    {"step": 4, "state": "SYNTHESIZE", "query": null, "reason": "synthesizing answer from 11 items", "results_count": 0},
    {"step": 5, "state": "VERIFY_ANSWER", "query": null, "reason": "verification complete, 0 warnings", "results_count": 0}
  ],
  "warnings": [],
  "insufficient_evidence": false,
  "meta": {}
}
```

---

## 8. Como Usar no Frontend

### Painel de Configuração de Busca

No composer (campo de pergunta), o painel "Mais opções" (botão ⚙) contém:

```
┌─ Modo de busca ─────────────────────────────┐
│ [?] Ajuda                                    │
│                                              │
│ [ ] Consulta agêntica                        │
│ Executa múltiplas buscas e reavalia os       │
│ resultados antes de responder. Pode ser      │
│ mais lento, mas melhora perguntas complexas. │
│                                              │
│ [ ] Mostrar percurso de pesquisa (oculto     │
│     até ativar consulta agêntica)            │
└──────────────────────────────────────────────┘
```

- **"Consulta agêntica"**: Ativa o modo `agentic`
- **"Mostrar percurso de pesquisa"**: Ativa `include_search_trace=true` (só visível quando consulta agêntica está ativa)

### Payload Enviado pelo Frontend

```javascript
// Estado do composer
const apiPayload = {
  query: pergunta,
  search_mode: agenticSearchMode ? "agentic" : "standard",
  include_search_trace: showSearchTrace && agenticSearchMode,
  // ... demais campos (persona, tribunal, tipos, etc.)
};
```

### Renderização do Trace

Quando `search_mode="agentic"` e `include_search_trace=true`, o painel de trace é renderizado abaixo do Dossiê Documental:

- Número do passo (bold)
- Estado FSM (SEARCH, EVALUATE_EVIDENCE, SYNTHESIZE, etc.)
- Quantidade de resultados
- Consulta executada (se houver)
- Motivo operacional (e.g., "round 1 conceptual query")
- Erro (se houver — destacado em vermelho)

Além do painel global de trace, cada resposta agêntica concluída renderiza um card expansível acima da síntese final: **"Plano e consultas do agente"**. Esse card usa `turn.meta.agentic_research_plan` e `turn.searchTrace`, ambos persistidos no histórico local do turno. O card mostra:

- resumo de consultas, documentos recuperados, documentos finais e alvo mínimo;
- facetas planejadas e respectiva cobertura;
- reconsultas por tribunal, faceta ou amostra baixa;
- lista das consultas executadas, resultado por consulta e erro operacional quando houver.

**O que NÃO é exposto:**
- Chain-of-thought ("I think", "let me")
- Prompts internos
- Deliberações privadas da LLM
- Dados sensíveis

---

## 9. Formato de Trace Operacional

O trace é uma lista de `SearchStep` ordenados:

```typescript
interface SearchStep {
  step: number;           // Ordem de execução (1-based)
  state: string;          // Estado FSM: SEARCH | EVALUATE_EVIDENCE | SYNTHESIZE | etc.
  query: string | null;   // Texto da consulta executada (null para estados sem query)
  reason: string;         // Descrição objetiva da operação
  results_count: number;   // Número de resultados recuperados
  error?: string;         // Mensagem de erro se houver
}
```

**Razões operacionais válidas (reason):**
- `"round 1 conceptual query"` — subconsulta conceitual do round 1
- `"gap facet search: <facet_id>"` — reconsulta temática para cobrir uma faceta obrigatória sem evidência
- `"post-gap facet coverage: missing=[...]"` — reavaliação após reconsultas por faceta
- `"round 2 anchored specific query"` — subconsulta específica ancorada em entidades extraídas
- `"coverage: has_relevant=True, missing=['temporal markers']"` — avaliação de cobertura
- `"synthesizing answer from N items"` — síntese em execução
- `"sufficient coverage, stopping expansion"` — cobertura suficiente, sem expansão
- `"max_queries reached, stopping"` — orçamento de consultas esgotado
- `"timeout, stopping expansion"` — timeout durante expansão

---

## 10. Warnings Possíveis

Os warnings são retornados no campo `warnings` da resposta e também logados no arquivo `logs/runtime/rag_backend.log`.

### Códigos Canônicos

| Código | Descrição | Causa |
|---|---|---|
| `minimax_cjk_detected` | Caracteres CJK detectados na saída do modelo | Geração MiniMax com contaminantes |
| `minimax_cjk_sanitized` | Caracteres CJK substituídos por espaço | Pós-processamento aplicou `sanitize_cjk` |
| `agentic_timeout` | Timeout atingido durante execução agêntica | `timeout_seconds` excedido |
| `insufficient_evidence` | Sem documentos relevantes para responder | Busca retornou vazio ou cobertura insuficiente |
| `search_partial_failure` | Erro em parte das subconsultas | Exceção durante uma subconsulta específica |
| `metadata_unavailable` | Metadados estruturados não disponíveis | Documento sem campos esperados |
| `agentic_budget_exhausted` | Orçamento de steps/queries esgotado | `max_steps` ou `max_queries` atingido |
| `unsupported_identifier_removed` | Identificador não suportado detectado e removido | Resposta contém identificador sem suporte em evidências |
| `agentic_max_steps_reached` | Número máximo de etapas agênticas atingido | Loop chegou a `max_steps` |
| `agentic_max_queries_reached` | Número máximo de consultas atingido | `max_queries` atingido |
| `agentic_stop_no_entities` | Parada por falta de entidades para ancoragem | Sem entidades extraídas para round 2 |

---

## 11. Limitações Conhecidas

1. **Sanitização CJK por espaço**: A regex substitui CJK por espaço simples — em palavras mistas (ex: "para中文") o resultado será "para " (espaço). Considerado seguro pois CJK nunca deve aparecer em texto jurídico PT-BR.

2. **Sem re-chamada ao modelo**: Quando CJK é detectado, o sistema sanitiza diretamente em vez de fazer retry com instrução explícita. Evita custo/latência adicional mas pode perder nuances.

3. **Trace operacional apenas quando solicitado**: `include_search_trace` é `false` por padrão. O frontend só exibe trace quando o usuário ativa manualmente.

4. **Fallback não documentado em API**: Se `search_mode="agentic"` mas `rag.agentic` não estiver disponível, a exceção sobe como 500 em vez de fallback documentado.

5. **Testes de integração com LLM real**: Os testes usam monkeypatch pesado; testes de promoção para produção precisam de mock behavior detalhado.

6. **search_keyword usa vetor zero como proxy FTS**: Em bases sem extensão FTS nativa, o fallback pode não ser ideal. Extensão futura pode expor FTS nativo.

7. **Escritório tests**: 15 testes de integração falham com 401 Unauthorized em ambiente de teste (sem servidor rodando com auth configurada). Falhas pré-existentes, não relacionadas às mudanças RAG.

---

## 12. Próximos Passos Recomendados

### Curto Prazo

1. **Expor `generation_diagnostics` no contrato de resposta**: Para que o frontend possa exibir informações de CJK detection ao operador.
2. **Persistência de preferências de busca**: Salvar `agenticSearchMode` e `showSearchTrace` em localStorage para sobreviver a reloads.
3. **Tooltip estilizado**: Substituir atributo `title` por popover CSS/styling para o botão de ajuda.
4. **Validação de schema em `agentic_options`**: O dict é passado diretamente sem validação — adicionar validação Pydantic.

### Médio Prazo

1. **FTS nativa em LanceDB**: Substituir fallback de vetor zero por busca FTS real quando disponível.
2. **Prompt de síntese via `build_system_prompt()`**: Unificar construção de prompts usando `rag/prompts.py` também para o modo planner.
3. **Resposta de insuficiência específica**: No modo agêntico, retornar mensagem indicando quais aspectos de cobertura faltaram (temporal markers, source diversity, etc.).
4. **Testes de integração com LLM mock**: Desenvolver mock detalhado do comportamento MiniMax para testes de integração completos.

### Longo Prazo

1. **Cache de evidências**: Para perguntas similares, reutilizar resultados de busca agregados sem refazer embedding.
2. **Busca por similaridade de jurisprudência**: Dado um caso do usuário, buscar casos similares com mesmo tema/classe sem depender de palavras-chave.
3. **UI de trace agêntico expandida**: Painel de steps com timeline visual, cores por estado, e possibilidade de expandir detalhes de cada consulta.
4. **Monitoramento de qualidade**: Dashboard com métricas de warnings por modelo, taxa de CJK detection, taxa de insuficiência de evidências, latência por query.
