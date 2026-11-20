#!/bin/bash
# Restauración de la BD Odoo desde un dump SQL plano (nombre fijo) + filestore
# Funciona tanto si los servicios estaban en 'stop' como si se hizo 'down' antes.
# Ejecutar desde la raíz del proyecto (donde está docker-compose.yml)
set -euo pipefail

PG_CONTAINER="postgres_sergio"              # Nombre del servicio/contenedor de Postgres
ODOO_CONTAINER="odoo_sergio"                # Nombre del servicio/contenedor de Odoo
PG_USER="odoo"                              # Usuario de la BD Postgres
DB_NAME="odoo"                              # Nombre de la BD a restaurar
BACKUP_DIR="./data/backups"                 # Directorio de backups en el host
BACKUP_SQL="${BACKUP_DIR}/${DB_NAME}.sql"   # Ruta completa del archivo SQL de backup

echo "======================================================="
echo " INICIANDO RESTAURACIÓN"
echo "======================================================="

# 1) Validar backup
if [[ ! -s "${BACKUP_SQL}" ]]; then
  echo "ERROR: No se encontró ${BACKUP_SQL} o está vacío"
  exit 1
fi

# 2) Parar Odoo (si existe)
echo "==> Parando Odoo..."
docker compose stop "${ODOO_CONTAINER}" 2>/dev/null || true

# 3) Levantar Postgres (cubre caso 'down')
echo "==> Levantando Postgres..."
docker compose up -d "${PG_CONTAINER}"

# 4) Esperar readiness de Postgres
echo "==> Esperando a que Postgres acepte conexiones..."
until docker exec "${PG_CONTAINER}" pg_isready -U "${PG_USER}" >/dev/null 2>&1; do
  echo "   -> Postgres arrancando, reintentando en 2s..."
  sleep 2
done
echo "Postgres listo."

# 5) Eliminar BD y recrear
echo "==> Eliminando BD '${DB_NAME}' si existe..."
docker exec "${PG_CONTAINER}" dropdb -U "${PG_USER}" --if-exists "${DB_NAME}"
echo "==> Creando BD '${DB_NAME}'..."
docker exec "${PG_CONTAINER}" createdb -U "${PG_USER}" "${DB_NAME}"

# 6) Restaurar datos
# Toda la salida de psql va a un log; en pantalla solo progreso y, si falla, el error.
RESTORE_LOG="${BACKUP_DIR}/restore.log"
echo "==> Restaurando datos desde ${BACKUP_SQL} ($(du -h "${BACKUP_SQL}" | cut -f1))..."

PSQL_CMD=(docker exec -i "${PG_CONTAINER}" psql -q -U "${PG_USER}" -d "${DB_NAME}" -v ON_ERROR_STOP=on)

set +e
if command -v pv >/dev/null 2>&1; then
  pv -p -t -e -r -b "${BACKUP_SQL}" | "${PSQL_CMD[@]}" > "${RESTORE_LOG}" 2>&1
  STATUS=${PIPESTATUS[1]}
else
  echo "   (instala 'pv' para ver barra de progreso: sudo apt install pv)"
  "${PSQL_CMD[@]}" < "${BACKUP_SQL}" > "${RESTORE_LOG}" 2>&1 &
  PID=$!
  SPIN='|/-\'; i=0
  while kill -0 "${PID}" 2>/dev/null; do
    printf "\r   Restaurando... %s" "${SPIN:i++%4:1}"
    sleep 0.3
  done
  wait "${PID}"; STATUS=$?
  printf "\r   Restaurando... hecho\n"
fi
set -e

if [[ ${STATUS} -ne 0 ]]; then
  echo ""
  echo "#######################################################"
  echo " ERROR en la restauración (código ${STATUS})"
  echo "#######################################################"
  grep -E "ERROR|FATAL|psql:" "${RESTORE_LOG}" | head -n 20 || tail -n 20 "${RESTORE_LOG}"
  echo ""
  echo "Log completo en: ${RESTORE_LOG}"
  echo "Odoo NO se ha arrancado."
  exit 1
fi

# Avisos no fatales (WARNING/NOTICE) por si interesa revisarlos
if grep -qE "WARNING" "${RESTORE_LOG}"; then
  echo "   Aviso: hay WARNINGs en ${RESTORE_LOG} (no fatales)."
fi
echo "Datos restaurados correctamente."

# 6.5) Restaurar Filestore
# Se hace DENTRO de un contenedor temporal de Odoo (como root), porque la carpeta
# ./data/odoo/filestore la crea Odoo como root y el usuario de WSL no puede escribir en ella.
if [[ -f "${BACKUP_DIR}/filestore.tar.gz" ]]; then
  echo "==> Restaurando archivos físicos (Filestore)..."
  docker compose run --rm --no-deps \
    -v "${BACKUP_DIR}:/backups:ro" \
    --entrypoint bash "${ODOO_CONTAINER}" -c \
    "rm -rf /var/lib/odoo/filestore/${DB_NAME} && tar -xzf /backups/filestore.tar.gz -C /var/lib/odoo/filestore"
else
  echo "WARNING: No se encontró filestore.tar.gz. Se regenerará al iniciar."
fi

echo "==> Limpiando referencias a assets antiguos en SQL..."
# Elimina los punteros a CSS/JS compilados en el PC de origen; Odoo los regenera
docker exec "${PG_CONTAINER}" psql -q -U "${PG_USER}" -d "${DB_NAME}" \
  -c "DELETE FROM ir_attachment WHERE url LIKE '/web/assets/%';"

echo "Restauración completada."

# 7) Levantar Odoo
echo "==> Levantando Odoo..."
docker compose up -d "${ODOO_CONTAINER}"

echo "======================================================="
echo " RESTAURACIÓN COMPLETA. Accede a: http://localhost:8069"
echo "======================================================="