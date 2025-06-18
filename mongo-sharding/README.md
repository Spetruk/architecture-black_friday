# pymongo-api

## Как запустить

Запускаем mongodb и приложение

```shell
docker compose up -d
```

Заполняем mongodb данными

```shell
./scripts/mongo-init.sh
```

## Как проверить

### Если вы запускаете проект на локальной машине

Выполнить curl http://localhost:8081/helloDoc/users/ly1

Как посмотреть распределение по шардам:
```shell
docker exec mongos_router mongosh --port 27020 --eval "
var db = db.getSiblingDB('somedb');
db.helloDoc.getShardDistribution();
"
```

Результат:
```shell
"
Shard shard1 at shard1/shard1:27018
{
  data: '21KiB',
  docs: 479,
  chunks: 2,
  'estimated data per chunk': '10KiB',
  'estimated docs per chunk': 239
}
---
Shard shard2 at shard2/shard2:27019
{
  data: '23KiB',
  docs: 521,
  chunks: 2,
  'estimated data per chunk': '11KiB',
  'estimated docs per chunk': 260
}
---
Totals
{
  data: '45KiB',
  docs: 1000,
  chunks: 4,
  'Shard shard1': [
    '47.91 % data',
    '47.9 % docs in cluster',
    '46B avg obj size on shard'
  ],
  'Shard shard2': [
    '52.08 % data',
    '52.1 % docs in cluster',
    '46B avg obj size on shard'
  ]
}
```