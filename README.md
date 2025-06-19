# pymongo-api

[task1.drawio](task1.drawio)


Перейти в папку sharding-repl-cache

```shell
cd sharding-repl-cache
```

Запускаем mongodb и приложение

```shell
docker compose up -d
```

Заполняем mongodb данными

```shell
./scripts/mongo-init.sh
```

Результат + можно проверишь время ответов на запросы (кеш работает):
```shell
...
[direct: mongos] somedb> ✅ Добавлено 1000 документов

[direct: mongos] somedb> 📊 Общее количество: 1000

Shard shard1 at shard1/shard1:27018,shard1b:27018,shard1c:27018
{
  data: '21KiB',
  docs: 479,
  chunks: 2,
  'estimated data per chunk': '10KiB',
  'estimated docs per chunk': 239
}
---
Shard shard2 at shard2/shard2:27019,shard2b:27019,shard2c:27019
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

ADRs:

[task7](tasks/task7.md)

[task8](tasks/task8.md)

[task9](tasks/task9.md)

[task10](tasks/task10.md)