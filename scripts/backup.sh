#!/bin/bash
# Backup de la BD Odoo (SQL plano) + filestore en ./data/backups
# Ejecutar desde la raíz del proyecto (donde está docker-compose.yml)
set -euo pipefail

PG_CONTAINER="postgres_sergio"              # Nombre del servicio/contenedor de Postgres
ODOO_CONTAINER="odoo_sergio"                # Nombre del servicio/contenedor de Odoo
PG_USER="odoo"                              # Usuario de la BD Postgres
DB_NAME="odoo"                              # Nombre de la BD a respaldar
BACKUP_DIR="./data/backups"                 # Directorio de backups en el host
BACKUP_SQL="${BACKUP_DIR}/${DB_NAME}.sql"   # Ruta completa del archivo SQL de backup
FILESTORE_DIR="./data/odoo/filestore"

echo "======================================================="
echo "    INICIANDO COPIA DE SEGURIDAD LOCAL"
echo "======================================================="

echo "==> Parando Odoo para garantizar consistencia..."
docker compose stop "${ODOO_CONTAINER}" 2>/dev/null || true

mkdir -p "${BACKUP_DIR}"

echo "==> Asegurando que Postgres está arrancado y listo..."
docker compose up -d "${PG_CONTAINER}"
until docker exec "${PG_CONTAINER}" pg_isready -U "${PG_USER}" >/dev/null 2>&1; do
  echo "   -> Postgres arrancando, reintentando en 2s..."
  sleep 2
done

echo "==> Creando backup lógico (SQL plano) de la BD '${DB_NAME}'..."
# El dump sale por stdout y lo escribe el usuario de WSL (no root).
# Se escribe primero en .tmp: si pg_dump falla, NO se machaca el backup bueno anterior.
docker exec "${PG_CONTAINER}" pg_dump -U "${PG_USER}" -d "${DB_NAME}" --no-owner --no-privileges \
  > "${BACKUP_SQL}.tmp"
mv "${BACKUP_SQL}.tmp" "${BACKUP_SQL}"
echo "Backup SQL completado: ${BACKUP_SQL}"

echo "==> Empaquetando Filestore..."
if [[ -d "${FILESTORE_DIR}" ]]; then
  tar -czf "${BACKUP_DIR}/filestore.tar.gz.tmp" -C "${FILESTORE_DIR}" .
  mv "${BACKUP_DIR}/filestore.tar.gz.tmp" "${BACKUP_DIR}/filestore.tar.gz"
  echo "Filestore empaquetado."
else
  echo "WARNING: no existe ${FILESTORE_DIR}; no se empaqueta filestore."
fi

echo "==> Arrancando Odoo de nuevo..."
docker compose start "${ODOO_CONTAINER}"

echo "FIN"
