#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUNTIME_DIR="$ROOT_DIR/logs/runtime"
CACHE_DIR="$ROOT_DIR/_cache/huggingface"

BACKEND_HOST="${DATAJUS_BACKEND_HOST:-0.0.0.0}"
BACKEND_PORT="${DATAJUS_BACKEND_PORT:-8000}"
FRONTEND_HOST="${DATAJUS_FRONTEND_HOST:-127.0.0.1}"
FRONTEND_PORT="${DATAJUS_FRONTEND_PORT:-5500}"

BACKEND_PID_FILE="$RUNTIME_DIR/backend.pid"
FRONTEND_PID_FILE="$RUNTIME_DIR/frontend.pid"
BACKEND_OUT="$RUNTIME_DIR/backend.out.log"
BACKEND_ERR="$RUNTIME_DIR/backend.err.log"
FRONTEND_OUT="$RUNTIME_DIR/frontend.out.log"
FRONTEND_ERR="$RUNTIME_DIR/frontend.err.log"

PYTHON_BIN="${PYTHON_BIN:-}"

usage() {
  cat <<EOF
Uso: ./datajus_server.sh [start|restart|stop|status]

Comandos:
  start     inicia backend e frontend se ainda nao estiverem ativos
  restart   encerra instancias gerenciadas e inicia novamente
  stop      encerra backend e frontend gerenciados
  status    mostra processos e health check local

Variaveis opcionais:
  PYTHON_BIN=/caminho/python
  DATAJUS_BACKEND_PORT=8000
  DATAJUS_FRONTEND_PORT=5500
EOF
}

resolve_python() {
  if [[ -n "$PYTHON_BIN" ]]; then
    return 0
  fi

  if [[ -x "$ROOT_DIR/.venv/bin/python" ]]; then
    PYTHON_BIN="$ROOT_DIR/.venv/bin/python"
  elif command -v python3 >/dev/null 2>&1; then
    PYTHON_BIN="$(command -v python3)"
  elif command -v python >/dev/null 2>&1; then
    PYTHON_BIN="$(command -v python)"
  else
    echo "[ERRO] Python 3.10+ nao encontrado no PATH." >&2
    exit 1
  fi
}

prepare_dirs() {
  mkdir -p "$RUNTIME_DIR" "$CACHE_DIR/hub" "$CACHE_DIR/transformers"
}

export_runtime_env() {
  export RATIO_PROJECT_ROOT="$ROOT_DIR"
  export HF_HOME="$CACHE_DIR"
  export HF_HUB_CACHE="$CACHE_DIR/hub"
  export TRANSFORMERS_CACHE="$CACHE_DIR/transformers"
}

pid_is_running() {
  local pid="${1:-}"
  [[ -n "$pid" ]] && kill -0 "$pid" >/dev/null 2>&1
}

read_pid_file() {
  local pid_file="$1"
  [[ -f "$pid_file" ]] || return 1
  local pid
  pid="$(tr -d '[:space:]' < "$pid_file")"
  pid_is_running "$pid" || return 1
  printf '%s\n' "$pid"
}

port_pid() {
  local port="$1"
  lsof -tiTCP:"$port" -sTCP:LISTEN -nP 2>/dev/null | head -n 1 || true
}

process_command() {
  local pid="$1"
  ps -p "$pid" -o command= 2>/dev/null || true
}

matches_backend() {
  local pid="$1"
  process_command "$pid" | grep -Eq 'uvicorn .*backend\.main:app|python.*-m uvicorn.*backend\.main:app'
}

matches_frontend() {
  local pid="$1"
  process_command "$pid" | grep -Eq 'frontend_server\.py|http\.server .*--directory frontend|python.*-m http\.server.*--directory frontend'
}

stop_pid() {
  local pid="$1"
  local label="$2"

  if ! pid_is_running "$pid"; then
    echo "[INFO] $label: processo $pid ja estava encerrado."
    return 0
  fi

  kill "$pid" >/dev/null 2>&1 || true
  for _ in {1..20}; do
    if ! pid_is_running "$pid"; then
      echo "[OK] $label: PID $pid encerrado."
      return 0
    fi
    sleep 0.2
  done

  kill -9 "$pid" >/dev/null 2>&1 || true
  echo "[OK] $label: PID $pid encerrado com kill -9."
}

stop_service() {
  local label="$1"
  local pid_file="$2"
  local port="$3"
  local matcher="$4"
  local pid=""

  if pid="$(read_pid_file "$pid_file" 2>/dev/null)"; then
    if "$matcher" "$pid"; then
      stop_pid "$pid" "$label"
    else
      echo "[AVISO] $label: PID $pid ignorado; comando nao parece ser do DataJus."
    fi
  else
    echo "[INFO] $label: PID file ausente ou antigo."
  fi
  rm -f "$pid_file"

  pid="$(port_pid "$port")"
  if [[ -n "$pid" ]]; then
    if "$matcher" "$pid"; then
      stop_pid "$pid" "$label"
    else
      echo "[INFO] $label: porta $port ocupada por outro processo; nao foi encerrado."
    fi
  fi
}

wait_for_url() {
  local url="$1"
  local label="$2"
  local max_tries="${3:-30}"

  for _ in $(seq 1 "$max_tries"); do
    if curl -fsS --max-time 2 "$url" >/dev/null 2>&1; then
      echo "[OK] $label pronto em $url"
      return 0
    fi
    sleep 1
  done

  echo "[ERRO] $label nao respondeu em $url." >&2
  return 1
}

start_backend() {
  local pid
  if pid="$(read_pid_file "$BACKEND_PID_FILE" 2>/dev/null)" && matches_backend "$pid"; then
    echo "[INFO] Backend ja esta ativo - PID $pid."
    return 0
  fi

  pid="$(port_pid "$BACKEND_PORT")"
  if [[ -n "$pid" ]]; then
    echo "[ERRO] Porta $BACKEND_PORT ja esta em uso por PID $pid:" >&2
    process_command "$pid" >&2
    return 1
  fi

  echo "[1/2] Iniciando backend FastAPI em http://$BACKEND_HOST:$BACKEND_PORT ..."
  (
    cd "$ROOT_DIR"
    nohup "$PYTHON_BIN" -m uvicorn backend.main:app --host "$BACKEND_HOST" --port "$BACKEND_PORT" \
      >"$BACKEND_OUT" 2>"$BACKEND_ERR" &
    echo $! > "$BACKEND_PID_FILE"
  )
  wait_for_url "http://$BACKEND_HOST:$BACKEND_PORT/health" "Backend" 45
}

start_frontend() {
  local pid
  if pid="$(read_pid_file "$FRONTEND_PID_FILE" 2>/dev/null)" && matches_frontend "$pid"; then
    echo "[INFO] Frontend ja esta ativo - PID $pid."
    return 0
  fi

  pid="$(port_pid "$FRONTEND_PORT")"
  if [[ -n "$pid" ]]; then
    echo "[ERRO] Porta $FRONTEND_PORT ja esta em uso por PID $pid:" >&2
    process_command "$pid" >&2
    return 1
  fi

  echo "[2/2] Iniciando frontend estatico em http://$FRONTEND_HOST:$FRONTEND_PORT ..."
  (
    cd "$ROOT_DIR"
    nohup "$PYTHON_BIN" frontend_server.py --host "$FRONTEND_HOST" --port "$FRONTEND_PORT" --directory frontend \
      >"$FRONTEND_OUT" 2>"$FRONTEND_ERR" &
    echo $! > "$FRONTEND_PID_FILE"
  )
  wait_for_url "http://$FRONTEND_HOST:$FRONTEND_PORT/" "Frontend" 10
}

start_all() {
  resolve_python
  prepare_dirs
  export_runtime_env
  start_backend
  start_frontend
  echo
  echo "DataJus iniciado:"
  echo "- Frontend: http://$FRONTEND_HOST:$FRONTEND_PORT"
  echo "- Backend : http://$BACKEND_HOST:$BACKEND_PORT"
  echo "- Logs    : $RUNTIME_DIR"
}

stop_all() {
  prepare_dirs
  stop_service "Backend" "$BACKEND_PID_FILE" "$BACKEND_PORT" matches_backend
  stop_service "Frontend" "$FRONTEND_PID_FILE" "$FRONTEND_PORT" matches_frontend
}

status_one() {
  local label="$1"
  local pid_file="$2"
  local port="$3"
  local url="$4"
  local pid=""

  if pid="$(read_pid_file "$pid_file" 2>/dev/null)"; then
    echo "$label: ativo pelo PID file - PID $pid"
  elif pid="$(port_pid "$port")" && [[ -n "$pid" ]]; then
    echo "$label: porta $port em uso - PID $pid"
    process_command "$pid"
  else
    echo "$label: parado"
  fi

  if curl -fsS --max-time 2 "$url" >/dev/null 2>&1; then
    echo "$label health: OK ($url)"
  else
    echo "$label health: sem resposta ($url)"
  fi
}

status_all() {
  status_one "Backend" "$BACKEND_PID_FILE" "$BACKEND_PORT" "http://$BACKEND_HOST:$BACKEND_PORT/health"
  status_one "Frontend" "$FRONTEND_PID_FILE" "$FRONTEND_PORT" "http://$FRONTEND_HOST:$FRONTEND_PORT/"
}

main() {
  local command="${1:-start}"

  case "$command" in
    start)
      start_all
      ;;
    restart)
      stop_all
      start_all
      ;;
    stop)
      stop_all
      ;;
    status)
      status_all
      ;;
    -h|--help|help)
      usage
      ;;
    *)
      usage >&2
      exit 2
      ;;
  esac
}

main "$@"
