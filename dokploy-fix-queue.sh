#!/bin/bash
set -e

POSTGRES=$(docker ps --filter name=dokploy-postgres --format '{{.Names}}' | head -1)
REDIS=$(docker ps --filter name=dokploy-redis --format '{{.Names}}' | head -1)

echo "[1/3] Resetando deployments travados no Postgres..."
docker exec $POSTGRES psql -U dokploy -d dokploy -c "UPDATE deployment SET status='error' WHERE status='running';"

echo "[2/3] Limpando keys bull:deployments:* no Redis..."
KEYS=$(docker exec $REDIS redis-cli KEYS 'bull:deployments:*')
if [ -n "$KEYS" ]; then
  echo "$KEYS" | xargs docker exec -i $REDIS redis-cli DEL
else
  echo "Nenhuma key encontrada."
fi

echo "[3/3] Reiniciando serviço Dokploy..."
docker service update --force dokploy

echo "Pronto!"
