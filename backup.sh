#!/bin/bash
# ============================================================================
# CADASTRAQUI — Backup PostgreSQL → Supabase Storage
# Roda dentro do Railway como serviço separado
# ============================================================================

set -euo pipefail

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] $1"
}

# ---------------------------------------------------------------------------
# VALIDAR VARIÁVEIS (configuradas no Railway Dashboard → Variables)
# ---------------------------------------------------------------------------

: "${DATABASE_URL:?ERRO: DATABASE_URL não definida}"
: "${SUPABASE_PROJECT_URL:?ERRO: SUPABASE_PROJECT_URL não definida}"
: "${SUPABASE_SERVICE_ROLE_KEY:?ERRO: SUPABASE_SERVICE_ROLE_KEY não definida}"

SUPABASE_BUCKET="${SUPABASE_BUCKET:-backups}"
LOCAL_RETENTION_COUNT="${LOCAL_RETENTION_COUNT:-5}"
REMOTE_RETENTION_DAYS="${REMOTE_RETENTION_DAYS:-30}"
BACKUP_DIR="/tmp/backups"

# ---------------------------------------------------------------------------
# CLEANUP EM CASO DE ERRO
# ---------------------------------------------------------------------------

DUMP_FILE=""
GZ_FILE=""

cleanup_on_error() {
  log "ERRO: Backup falhou na linha $1"
  [ -f "$DUMP_FILE" ] && rm -f "$DUMP_FILE"
  [ -f "$GZ_FILE" ] && rm -f "$GZ_FILE"
  exit 1
}

trap 'cleanup_on_error $LINENO' ERR

# ---------------------------------------------------------------------------
# INÍCIO
# ---------------------------------------------------------------------------

log "========== INÍCIO DO BACKUP =========="

mkdir -p "$BACKUP_DIR"

TIMESTAMP=$(date '+%Y%m%d_%H%M%S')
DUMP_FILE="$BACKUP_DIR/cadastraqui_${TIMESTAMP}.dump"
GZ_FILE="${DUMP_FILE}.gz"
REMOTE_FILENAME="cadastraqui_${TIMESTAMP}.dump.gz"

# ---------------------------------------------------------------------------
# 1. pg_dump (usa DATABASE_URL interna — sem custo de egress)
# ---------------------------------------------------------------------------

log "1/5 - Executando pg_dump..."

pg_dump "$DATABASE_URL" \
  --no-owner \
  --no-acl \
  --no-comments \
  --format=custom \
  --compress=0 \
  -f "$DUMP_FILE"

DUMP_SIZE=$(du -h "$DUMP_FILE" | cut -f1)
log "     Dump OK ($DUMP_SIZE)"

# ---------------------------------------------------------------------------
# 2. Compactar
# ---------------------------------------------------------------------------

log "2/5 - Compactando..."

gzip -9 "$DUMP_FILE"

GZ_SIZE=$(du -h "$GZ_FILE" | cut -f1)
log "     Compactado ($GZ_SIZE)"

# ---------------------------------------------------------------------------
# 3. Upload para Supabase Storage
# ---------------------------------------------------------------------------

log "3/5 - Upload para Supabase (bucket: $SUPABASE_BUCKET)..."

HTTP_STATUS=$(curl -s -o /tmp/upload_response.json -w "%{http_code}" \
  -X POST \
  "${SUPABASE_PROJECT_URL}/storage/v1/object/${SUPABASE_BUCKET}/${REMOTE_FILENAME}" \
  -H "Authorization: Bearer ${SUPABASE_SERVICE_ROLE_KEY}" \
  -H "Content-Type: application/octet-stream" \
  -H "x-upsert: true" \
  --data-binary "@${GZ_FILE}")

if [ "$HTTP_STATUS" -ge 200 ] && [ "$HTTP_STATUS" -lt 300 ]; then
  log "     Upload OK (HTTP $HTTP_STATUS)"
else
  RESPONSE=$(cat /tmp/upload_response.json 2>/dev/null || echo "sem resposta")
  log "     ERRO no upload (HTTP $HTTP_STATUS): $RESPONSE"
  rm -f /tmp/upload_response.json
  exit 1
fi

rm -f /tmp/upload_response.json

# ---------------------------------------------------------------------------
# 4. Limpar backups locais
# ---------------------------------------------------------------------------

log "4/5 - Limpando backups locais (mantendo últimos $LOCAL_RETENTION_COUNT)..."

LOCAL_COUNT=$(ls -1t "$BACKUP_DIR"/cadastraqui_*.dump.gz 2>/dev/null | wc -l)

if [ "$LOCAL_COUNT" -gt "$LOCAL_RETENTION_COUNT" ]; then
  REMOVED=$(ls -1t "$BACKUP_DIR"/cadastraqui_*.dump.gz | tail -n +$((LOCAL_RETENTION_COUNT + 1)))
  echo "$REMOVED" | xargs rm -f
  REMOVED_COUNT=$(echo "$REMOVED" | wc -l)
  log "     Removidos $REMOVED_COUNT backups locais"
else
  log "     OK ($LOCAL_COUNT <= $LOCAL_RETENTION_COUNT)"
fi

# ---------------------------------------------------------------------------
# 5. Limpar backups antigos no Supabase
# ---------------------------------------------------------------------------

log "5/5 - Limpando backups remotos (> $REMOTE_RETENTION_DAYS dias)..."

FILES_JSON=$(curl -s \
  -X POST \
  "${SUPABASE_PROJECT_URL}/storage/v1/object/list/${SUPABASE_BUCKET}" \
  -H "Authorization: Bearer ${SUPABASE_SERVICE_ROLE_KEY}" \
  -H "Content-Type: application/json" \
  -d '{"prefix": "cadastraqui_", "limit": 1000, "sortBy": {"column": "created_at", "order": "asc"}}')

CUTOFF_DATE=$(date -d "-${REMOTE_RETENTION_DAYS} days" '+%Y-%m-%dT%H:%M:%S')

OLD_FILES=$(echo "$FILES_JSON" | python3 -c "
import sys, json
from datetime import datetime

cutoff = datetime.strptime('$CUTOFF_DATE', '%Y-%m-%dT%H:%M:%S')
try:
    files = json.load(sys.stdin)
    if not isinstance(files, list):
        sys.exit(0)
    for f in files:
        name = f.get('name', '')
        if not name.startswith('cadastraqui_'):
            continue
        try:
            ts_str = name.replace('cadastraqui_', '').replace('.dump.gz', '')
            file_date = datetime.strptime(ts_str, '%Y%m%d_%H%M%S')
            if file_date < cutoff:
                print(name)
        except ValueError:
            continue
except (json.JSONDecodeError, KeyError):
    pass
" 2>/dev/null || echo "")

if [ -n "$OLD_FILES" ]; then
  DELETE_PAYLOAD=$(echo "$OLD_FILES" | python3 -c "
import sys, json
files = [line.strip() for line in sys.stdin if line.strip()]
print(json.dumps({'prefixes': files}))
")

  curl -s -o /dev/null \
    -X DELETE \
    "${SUPABASE_PROJECT_URL}/storage/v1/object/${SUPABASE_BUCKET}" \
    -H "Authorization: Bearer ${SUPABASE_SERVICE_ROLE_KEY}" \
    -H "Content-Type: application/json" \
    -d "$DELETE_PAYLOAD"

  OLD_COUNT=$(echo "$OLD_FILES" | wc -l | tr -d ' ')
  log "     Removidos $OLD_COUNT backups remotos antigos"
else
  log "     Nenhum para remover"
fi

# ---------------------------------------------------------------------------
# RESUMO
# ---------------------------------------------------------------------------

log "========== BACKUP CONCLUÍDO =========="
log "  Arquivo: $REMOTE_FILENAME"
log "  Tamanho: $GZ_SIZE"
log "  Destino: ${SUPABASE_BUCKET}/${REMOTE_FILENAME}"
log "======================================="
