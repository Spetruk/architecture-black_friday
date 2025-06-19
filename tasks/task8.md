# Architecture Design Record: Устранение горячих шардов и балансировка нагрузки в MongoDB

## Название задачи
Разработка стратегии выявления и устранения горячих шардов в коллекции products

## Контекст и проблема

После запуска шардированной MongoDB обнаружилась критическая проблема: шард, содержащий категорию "electronics", обрабатывает 70% всех запросов к коллекции products. Это привело к:
- Деградации производительности (время отклика увеличилось с 100мс до 800мс)
- Перегрузке CPU на узлах шарда (utilization > 85%)
- Неравномерному использованию ресурсов кластера
- Риску отказа при дальнейшем росте нагрузки

Текущая стратегия шардирования `{ category: 1, _id: "hashed" }` не обеспечивает равномерного распределения нагрузки из-за неравномерной популярности категорий.

## Функциональные требования

### Use Cases для решения

| № | Действующие лица | Use Case | Описание |
|---|-----------------|----------|----------|
| UC1 | Система мониторинга, DevOps инженер | Выявление горячих шардов | 1. Система собирает метрики с шардов<br>2. При превышении пороговых значений создаётся алерт<br>3. DevOps получает уведомление с деталями проблемы |
| UC2 | Автоматическая система балансировки | Перераспределение нагрузки | 1. Система анализирует распределение данных<br>2. Определяет стратегию разделения чанков<br>3. Инициирует миграцию данных между шардами |
| UC3 | DevOps инженер, DBA | Ручная оптимизация | 1. Инженер анализирует паттерны нагрузки<br>2. Принимает решение о изменении стратегии<br>3. Выполняет миграцию или изменение шард-ключа |

## Нефункциональные требования

| № | Требование | Описание |
|---|------------|----------|
| NFR1 | Время обнаружения | Выявление дисбаланса в течение 5 минут |
| NFR2 | Автоматизация | 80% случаев должны решаться автоматически |
| NFR3 | Влияние на производительность | Миграция не должна снижать производительность > 10% |
| NFR4 | Предсказуемость | Система должна предупреждать о потенциальных hotspots |
| NFR5 | Масштабируемость мониторинга | Поддержка до 100 шардов |

## Решение

### 1. Система метрик мониторинга

#### Базовые метрики распределения данных

```javascript
// Метрика 1: Размер данных по шардам
function getShardDataDistribution() {
  const shards = db.getSiblingDB("config").shards.find().toArray();
  const stats = {};
  
  shards.forEach(shard => {
    const shardStats = db.getSiblingDB("shop").runCommand({
      dbStats: 1,
      scale: 1024 * 1024 * 1024  // GB
    });
    stats[shard._id] = {
      dataSize: shardStats.dataSize,
      indexSize: shardStats.indexSize,
      collections: shardStats.collections
    };
  });
  
  return stats;
}

// Метрика 2: Количество чанков по шардам
function getChunkDistribution() {
  return db.getSiblingDB("config").chunks.aggregate([
    { $group: {
      _id: "$shard",
      count: { $sum: 1 },
      collections: { $addToSet: "$ns" }
    }},
    { $sort: { count: -1 }}
  ]).toArray();
}

// Метрика 3: Распределение по категориям
function getCategoryDistribution() {
  return db.products.aggregate([
    { $group: {
      _id: { 
        category: "$category",
        shard: { $meta: "shard" }
      },
      count: { $sum: 1 },
      totalSize: { $sum: "$size" }
    }},
    { $sort: { count: -1 }}
  ]).toArray();
}
```

#### Метрики производительности

```javascript
// Метрика 4: Операции по шардам (ops/sec)
function getShardOperationsRate() {
  const mongosStats = db.serverStatus();
  return {
    opcounters: mongosStats.opcounters,
    opcountersRepl: mongosStats.opcountersRepl,
    shardingStatistics: mongosStats.shardingStatistics
  };
}

// Метрика 5: Latency percentiles по шардам
function getShardLatencyMetrics() {
  return db.getSiblingDB("admin").aggregate([
    { $currentOp: { allUsers: true }},
    { $match: { type: "op" }},
    { $group: {
      _id: "$shard",
      avgMs: { $avg: "$microsecs_running" },
      maxMs: { $max: "$microsecs_running" },
      p95Ms: { $percentile: { 
        input: "$microsecs_running", 
        p: [0.95] 
      }}
    }}
  ]).toArray();
}
```

#### Метрики ресурсов

```javascript
// Метрика 6: CPU и память по шардам
function getShardResourceMetrics() {
  const shards = sh.status().shards;
  const metrics = {};
  
  shards.forEach(shard => {
    const conn = new Mongo(shard.host);
    const serverStatus = conn.getDB("admin").serverStatus();
    
    metrics[shard._id] = {
      cpu: {
        user: serverStatus.extra_info.user_time_us,
        system: serverStatus.extra_info.system_time_us
      },
      memory: {
        resident: serverStatus.mem.resident,
        virtual: serverStatus.mem.virtual,
        mapped: serverStatus.mem.mapped
      },
      connections: serverStatus.connections.current
    };
  });
  
  return metrics;
}
```

### 2. Система автоматического выявления hotspots

```javascript
// Конфигурация пороговых значений
const THRESHOLDS = {
  dataImbalance: 0.3,      // 30% отклонение от среднего
  opsImbalance: 0.4,       // 40% отклонение операций
  cpuThreshold: 0.75,      // 75% CPU utilization
  latencyThreshold: 200,   // 200ms p95 latency
  chunkImbalance: 0.25     // 25% отклонение чанков
};

// Функция детекции hotspots
function detectHotspots() {
  const alerts = [];
  
  // Проверка дисбаланса данных
  const shardSizes = getShardDataDistribution();
  const avgSize = Object.values(shardSizes)
    .reduce((sum, s) => sum + s.dataSize, 0) / Object.keys(shardSizes).length;
  
  Object.entries(shardSizes).forEach(([shard, stats]) => {
    const deviation = Math.abs(stats.dataSize - avgSize) / avgSize;
    if (deviation > THRESHOLDS.dataImbalance) {
      alerts.push({
        type: "DATA_IMBALANCE",
        severity: deviation > 0.5 ? "CRITICAL" : "WARNING",
        shard: shard,
        deviation: deviation,
        size: stats.dataSize,
        avgSize: avgSize
      });
    }
  });
  
  // Проверка производительности
  const latencyMetrics = getShardLatencyMetrics();
  latencyMetrics.forEach(metric => {
    if (metric.p95Ms > THRESHOLDS.latencyThreshold) {
      alerts.push({
        type: "HIGH_LATENCY",
        severity: "CRITICAL",
        shard: metric._id,
        p95Latency: metric.p95Ms
      });
    }
  });
  
  return alerts;
}
```

### 3. Стратегии устранения дисбаланса

#### Стратегия 1: Автоматическое разделение горячих чанков

```javascript
// Функция для разделения крупных чанков в горячих категориях
function splitHotCategoryChunks(category, targetChunkSize = 64) {
  // Найти все чанки для категории
  const chunks = db.getSiblingDB("config").chunks.find({
    ns: "shop.products",
    "min.category": category,
    "max.category": category
  }).toArray();
  
  chunks.forEach(chunk => {
    // Оценить размер чанка
    const chunkSize = db.products.count({
      category: category,
      _id: { 
        $gte: chunk.min._id,
        $lt: chunk.max._id
      }
    });
    
    if (chunkSize > targetChunkSize * 1000) {
      // Разделить чанк
      const splitPoint = {
        category: category,
        _id: ObjectId()  // Случайная точка разделения
      };
      
      sh.splitAt("shop.products", splitPoint);
      print(`Split chunk for category ${category} at ${splitPoint._id}`);
    }
  });
}

// Автоматическое разделение для горячих категорий
function autoSplitHotCategories() {
  const hotCategories = db.products.aggregate([
    { $group: { 
      _id: "$category", 
      count: { $sum: 1 }
    }},
    { $sort: { count: -1 }},
    { $limit: 5 }
  ]).toArray();
  
  hotCategories.forEach(cat => {
    if (cat.count > 100000) {  // Более 100k товаров
      splitHotCategoryChunks(cat._id, 32);  // Меньшие чанки
    }
  });
}
```

#### Стратегия 2: Перераспределение чанков между шардами

```javascript
// Функция балансировки чанков
function rebalanceChunks() {
  // Включить балансировщик с агрессивными настройками
  sh.enableBalancing("shop.products");
  
  // Установить окно балансировки 24/7
  db.getSiblingDB("config").settings.update(
    { _id: "balancer" },
    { $set: { 
      activeWindow: { start: "00:00", stop: "23:59" },
      _secondaryThrottle: true,
      _waitForDelete: true
    }},
    { upsert: true }
  );
  
  // Уменьшить размер чанков для лучшего распределения
  db.getSiblingDB("config").settings.update(
    { _id: "chunksize" },
    { $set: { value: 32 }},  // 32MB вместо 64MB по умолчанию
    { upsert: true }
  );
  
  // Форсировать балансировку
  sh.startBalancer();
}

// Ручное перемещение чанков с горячего шарда
function moveChunksFromHotShard(hotShardId, targetShardId, numChunks = 10) {
  const chunks = db.getSiblingDB("config").chunks.find({
    ns: "shop.products",
    shard: hotShardId
  }).limit(numChunks).toArray();
  
  chunks.forEach(chunk => {
    try {
      sh.moveChunk("shop.products", chunk.min, targetShardId);
      print(`Moved chunk from ${hotShardId} to ${targetShardId}`);
    } catch (e) {
      print(`Failed to move chunk: ${e}`);
    }
  });
}
```

#### Стратегия 3: Изменение шард-ключа (для критических случаев)

```javascript
// Новая стратегия шардирования с учётом популярности
function reshardWithCompoundKey() {
  // Добавить поле popularity_score в документы
  db.products.updateMany(
    {},
    [{
      $set: {
        popularity_score: {
          $switch: {
            branches: [
              { case: { $eq: ["$category", "electronics"] }, then: 10 },
              { case: { $eq: ["$category", "clothing"] }, then: 5 },
              { case: { $eq: ["$category", "books"] }, then: 3 }
            ],
            default: 1
          }
        }
      }
    }]
  );
  
  // Создать новую коллекцию с улучшенным шард-ключом
  db.createCollection("products_v2");
  
  // Новый составной шард-ключ
  sh.shardCollection("shop.products_v2", {
    popularity_score: 1,
    category: 1,
    _id: "hashed"
  });
  
  // Миграция данных
  db.products.aggregate([
    { $match: {} },
    { $out: "products_v2" }
  ]);
}
```

### 4. Система автоматического реагирования

```javascript
// Автоматический обработчик hotspots
class HotspotMitigator {
  constructor(config) {
    this.config = config;
    this.alertHistory = [];
  }
  
  async runMitigationCycle() {
    const alerts = detectHotspots();
    
    for (const alert of alerts) {
      switch (alert.type) {
        case "DATA_IMBALANCE":
          if (alert.severity === "CRITICAL") {
            await this.handleDataImbalance(alert);
          }
          break;
          
        case "HIGH_LATENCY":
          await this.handleHighLatency(alert);
          break;
      }
      
      this.alertHistory.push({
        ...alert,
        timestamp: new Date(),
        action_taken: true
      });
    }
  }
  
  async handleDataImbalance(alert) {
    // Автоматическое разделение чанков
    if (alert.deviation > 0.5) {
      print(`CRITICAL: Shard ${alert.shard} has ${alert.deviation * 100}% deviation`);
      
      // Найти самые большие чанки на перегруженном шарде
      const bigChunks = db.getSiblingDB("config").chunks.find({
        shard: alert.shard,
        ns: "shop.products"
      }).sort({ size: -1 }).limit(20);
      
      // Разделить большие чанки
      bigChunks.forEach(chunk => {
        const midpoint = calculateChunkMidpoint(chunk);
        sh.splitAt("shop.products", midpoint);
      });
      
      // Запустить балансировку
      sh.startBalancer();
    }
  }
  
  async handleHighLatency(alert) {
    // Временно перенаправить трафик
    print(`HIGH LATENCY on shard ${alert.shard}: ${alert.p95Latency}ms`);
    
    // Уведомить приложение о необходимости использовать read preference
    // для чтения с других шардов
    notifyApplication({
      action: "AVOID_SHARD",
      shard: alert.shard,
      duration: 300  // 5 минут
    });
  }
}

// Вспомогательная функция для расчёта точки разделения
function calculateChunkMidpoint(chunk) {
  if (chunk.min.category === chunk.max.category) {
    // Для чанков одной категории - разделить по _id
    return {
      category: chunk.min.category,
      _id: ObjectId.createFromTime(
        (chunk.min._id.getTimestamp() + chunk.max._id.getTimestamp()) / 2
      )
    };
  }
  return chunk.min;  // Для разных категорий - использовать минимум
}
```

### 5. Интеграция с системами мониторинга

#### Prometheus метрики + можно сделать Grafana дашборд 

```javascript
// Экспортер метрик для Prometheus
const prometheusMetrics = {
  // Gauge метрики для размера шардов
  'mongodb_shard_size_bytes': function() {
    const stats = getShardDataDistribution();
    return Object.entries(stats).map(([shard, data]) => ({
      labels: { shard: shard },
      value: data.dataSize * 1024 * 1024 * 1024
    }));
  },
  
  // Counter для операций по шардам
  'mongodb_shard_operations_total': function() {
    const ops = getShardOperationsRate();
    return Object.entries(ops.shardingStatistics.shardOperations)
      .map(([shard, count]) => ({
        labels: { shard: shard },
        value: count
      }));
  },
  
  // Histogram для latency
  'mongodb_shard_operation_duration_milliseconds': function() {
    const latency = getShardLatencyMetrics();
    return latency.map(metric => ({
      labels: { shard: metric._id },
      buckets: {
        '50': metric.p50Ms,
        '95': metric.p95Ms,
        '99': metric.p99Ms
      }
    }));
  }
};
```


### 6. Runbook для операционной команды

```bash
#!/bin/bash
# hotspot_mitigation_runbook.sh

# 1. Проверить текущее состояние
echo "=== Checking shard status ==="
mongo --eval "sh.status()" | grep -A 5 "shards:"

# 2. Выявить hotspots
echo "=== Detecting hotspots ==="
mongo --eval "
  load('hotspot_detection.js');
  const alerts = detectHotspots();
  printjson(alerts);
"

# 3. Проверить балансировщик
echo "=== Balancer status ==="
mongo --eval "sh.getBalancerState()"

# 4. При необходимости - экстренные меры
if [ "$1" == "emergency" ]; then
  echo "=== Emergency mitigation ==="
  mongo --eval "
    // Уменьшить размер чанков
    db.getSiblingDB('config').settings.update(
      { _id: 'chunksize' },
      { \$set: { value: 16 }},
      { upsert: true }
    );
    
    // Форсировать балансировку
    sh.startBalancer();
    
    // Разделить горячие чанки
    autoSplitHotCategories();
  "
fi

# 5. Мониторинг прогресса
echo "=== Monitoring migration progress ==="
watch -n 5 'mongo --eval "sh.status()" | grep "chunks:"'
```

## Альтернативы

### Альтернатива: Полный переход на hash-based sharding
**Описание:** Использовать только `{ _id: "hashed" }` для равномерного распределения.

**Преимущества:**
- Гарантированное равномерное распределение
- Простота реализации

**Недостатки:**
- Потеря возможности targeted queries по категориям
- Увеличение scatter-gather операций
- Снижение производительности чтения




## Недостатки, ограничения, риски

### Недостатки:
1. **Сложность автоматизации** - не все сценарии можно решить автоматически
2. **Влияние на производительность** во время миграции чанков
3. **Увеличение операционной нагрузки** на команду поддержки

### Ограничения:
1. **Минимальный размер чанка** - 1MB (нельзя разделить меньше)
2. **Скорость миграции** ограничена пропускной способностью сети
3. **Невозможность изменить шард-ключ** без пересоздания коллекции

### Риски:
1**Риск недоступности** при перемещении больших чанков
   - *Митигация:* Миграция в периоды низкой нагрузки
   
2**Риск потери производительности** при чрезмерном дроблении
   - *Митигация:* Мониторинг количества чанков

## Заключение

Предложенное решение обеспечивает:
- **Проактивное выявление** потенциальных hotspots через систему метрик
- **Автоматическое реагирование** на большинство сценариев дисбаланса
- **Гибкие стратегии** митигации в зависимости от типа проблемы
- **Интеграцию с существующими** системами мониторинга

Внедрение данной системы позволит поддерживать равномерное распределение нагрузки и предотвращать деградацию производительности из-за горячих шардов.