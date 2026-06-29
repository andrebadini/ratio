# TEI/vLLM Ubuntu para EmbeddingGemma 300M

Este arquivo documenta o caminho de conexao com o servidor Ubuntu na Tailscale. O backend publico do DataJus usa o endpoint OpenAI-compatible do Ubuntu como primario quando validado, mantendo o LM Studio local como fallback operacional.

## Host

- Tailscale IP: `100.80.18.44`
- API OpenAI-compatible: `http://100.80.18.44:8000/v1`
- SSH comum na porta `22` nao estava disponivel na ultima verificacao local; a API vLLM respondia em `8000`.

## Perfil alvo

O perfil desejado para compatibilidade com o LanceDB legado e:

```env
EMBEDDING_PROVIDER="lm_studio"
EMBED_MODEL="text-embedding-embeddinggemma-300m"
EMBEDDING_BASE_URL="http://100.80.18.44:8000/v1"
EMBEDDING_API_KEY="<chave-do-tei>"
EMBEDDING_FALLBACK_ENABLED="1"
EMBEDDING_FALLBACK_MODEL="text-embedding-embeddinggemma-300m"
EMBEDDING_FALLBACK_BASE_URL="http://127.0.0.1:1234/v1"
EMBEDDING_FALLBACK_API_KEY="lm-studio"
EMBED_BATCH_SIZE="128"
EMBED_DIM="768"
EMBED_NATIVE_DIM="768"
EMBED_DIM_REDUCTION="none"
EMBEDDING_PROFILE_ID="legacy_768"
```

Nao configure `LANCEDB_TABLE_SUFFIX` para esse perfil. As tabelas em producao ja estao em 768 dimensoes.

## Validacao da API

Use a chave local configurada em ambiente; nao registre a chave em logs ou documentos.

```bash
set -a
source .env
set +a

curl -fsS \
  -H "Authorization: Bearer ${EMBEDDING_API_KEY}" \
  http://100.80.18.44:8000/v1/models
```

Se o backend for TEI, `/v1/models` pode responder `404`. Nesse caso, use `/v1/embeddings` como gate autoritativo.

Validacao de dimensao:

```bash
set -a
source .env
set +a

EMBEDDING_PROVIDER=openai_compatible \
EMBED_MODEL=text-embedding-embeddinggemma-300m \
EMBEDDING_BASE_URL=http://100.80.18.44:8000/v1 \
EMBEDDING_API_KEY="${EMBEDDING_API_KEY}" \
EMBED_DIM=768 \
.venv/bin/python - <<'PY'
from rag.query import embed_texts

vec = embed_texts(["teste de embedding remoto"], task_type="RETRIEVAL_QUERY")[0]
print(len(vec))
PY
```

O resultado esperado e `768`.

## Cutover seguro

1. Confirmar `/v1/embeddings` com vetor de 768 dimensoes.
2. Confirmar embedding real com vetor de 768 dimensoes.
3. Alterar `.env` para o bloco acima, mantendo o fallback local.
4. Reiniciar o backend DataJus.
5. Validar `/health` e uma consulta real contra a tabela legada.

Nao reindexar o LanceDB legado para essa troca; o objetivo e apenas mover o runtime de embedding para o Ubuntu mantendo o contrato 768 atual.
