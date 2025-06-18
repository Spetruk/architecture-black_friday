#!/bin/bash

docker exec -it configSrv mongosh --port 27017 --eval "
rs.initiate(
  {
    _id : 'config_server',
       configsvr: true,
    members: [
      { _id : 0, host : 'configSrv:27017' }
    ]
  }
);
exit();
"

docker exec -it shard1 mongosh --port 27018 --eval "
rs.initiate(
    {
      _id : 'shard1',
      members: [
        { _id : 0, host : 'shard1:27018' }
      ]
    }
);
exit();
"

docker exec -it shard2 mongosh --port 27019 --eval "
rs.initiate(
    {
      _id : 'shard2',
      members: [
        { _id : 0, host : 'shard2:27019' }
      ]
    }
  );
exit();
"

docker exec -i mongos_router mongosh --port 27020 <<EOF
sh.addShard('shard1/shard1:27018');
sh.addShard('shard2/shard2:27019');
sh.enableSharding('somedb');
sh.shardCollection('somedb.helloDoc', { age: 'hashed' });
var db = db.getSiblingDB('somedb');
for (var i = 0; i < 1000; i++) db.helloDoc.insert({ age: i, name: "ly" + i });
print('✅ Добавлено 1000 документов');
print('📊 Общее количество: ' + db.helloDoc.countDocuments());
EOF

docker exec mongos_router mongosh --port 27020 --eval "
var db = db.getSiblingDB('somedb');
db.helloDoc.getShardDistribution();
"