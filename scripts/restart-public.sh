#!/usr/bin/env bash
# scripts/restart-public.sh
# Script para reiniciar o servidor DataJus de forma segura.

set -euo pipefail

# Caminho raiz do projeto
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

echo "--- [RESTART] Reiniciando servidor DataJus ---"

# Verifica se o script de gerenciamento existe
if [ ! -f "./datajus_server.sh" ]; then
    echo "[ERRO] Script ./datajus_server.sh não encontrado na raiz!"
    exit 1
fi

# Dá permissão de execução se necessário
chmod +x ./datajus_server.sh

# Executa o restart (o datajus_server.sh já lida com PIDs e portas)
./datajus_server.sh restart

echo "--- [RESTART] Servidor reiniciado com sucesso! ---"
