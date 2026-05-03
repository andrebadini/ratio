#!/usr/bin/env bash
# scripts/build-public.sh
# Script para atualizar dependências e aplicar alterações locais.

set -euo pipefail

# Caminho raiz do projeto
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

echo "--- [BUILD] Iniciando processo de atualização ---"

# 1. Tentar atualizar do repositório (opcional, falha silenciosamente se não houver remote)
if [ -d ".git" ]; then
    echo "[INFO] Verificando atualizações no git..."
    # Usamos stash para não perder alterações locais se houver conflito simples
    git stash -u > /dev/null 2>&1 || true
    git pull --rebase || echo "[AVISO] Não foi possível fazer git pull automático."
    git stash pop > /dev/null 2>&1 || true
fi

# 2. Resolver Python e ambiente virtual
PYTHON_BIN=""
if [[ -x "$ROOT_DIR/.venv/bin/python" ]]; then
    PYTHON_BIN="$ROOT_DIR/.venv/bin/python"
elif command -v python3 >/dev/null 2>&1; then
    PYTHON_BIN="$(command -v python3)"
else
    PYTHON_BIN="python"
fi

# 3. Atualizar dependências
echo "[INFO] Atualizando dependências do Python..."
"$PYTHON_BIN" -m pip install -q --upgrade pip
"$PYTHON_BIN" -m pip install -q -r requirements.txt

# 4. Frontend (Estático)
# Como o frontend é HTML/JS puro, não há build step do Vite aqui.
# Apenas garantimos que a pasta existe.
if [ ! -d "frontend" ]; then
    echo "[ERRO] Pasta 'frontend/' não encontrada!"
    exit 1
fi

echo "--- [BUILD] Concluído com sucesso! ---"
