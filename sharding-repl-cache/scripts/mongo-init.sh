#!/bin/bash

echo "🧩 Инициализация config server..."
docker exec -i configSrv mongosh --port 27017 --eval "
rs.initiate({
  _id: 'config_server',
  configsvr: true,
  members: [{ _id: 0, host: 'configSrv:27017' }]
});
"

echo "🧩 Инициализация shard1 replica set..."
docker exec -i shard1 mongosh --port 27018 --eval "
rs.initiate({
  _id: 'shard1',
  members: [
    { _id: 0, host: 'shard1:27018' },
    { _id: 1, host: 'shard1b:27018' },
    { _id: 2, host: 'shard1c:27018' }
  ]
});
"

echo "🧩 Инициализация shard2 replica set..."
docker exec -i shard2 mongosh --port 27019 --eval "
rs.initiate({
  _id: 'shard2',
  members: [
    { _id: 0, host: 'shard2:27019' },
    { _id: 1, host: 'shard2b:27019' },
    { _id: 2, host: 'shard2c:27019' }
  ]
});
"

echo "🧩 Настройка mongos и добавление шардов..."
docker exec -i mongos_router mongosh --port 27020 --eval "
sh.addShard('shard1/shard1:27018,shard1b:27018,shard1c:27018');
sh.addShard('shard2/shard2:27019,shard2b:27019,shard2c:27019');
sh.enableSharding('somedb');
sh.shardCollection('somedb.helloDoc', { age: 'hashed' });
var db = db.getSiblingDB('somedb');
for (var i = 0; i < 1000; i++) db.helloDoc.insert({ age: i, name: 'ly' + i });
print('✅ Добавлено 1000 документов');
print('📊 Всего документов: ' + db.helloDoc.countDocuments());
"


docker exec mongos_router mongosh --port 27020 --eval "
var db = db.getSiblingDB('somedb');
db.helloDoc.getShardDistribution();
"