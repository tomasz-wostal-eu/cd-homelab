// =============================================================================
// Zapytania Flux dla świateł akwarium - InfluxDB bucket: mqtt
// Używaj w Grafana - automatycznie dostosowuje się do wybranego zakresu czasu
// =============================================================================

// -----------------------------------------------------------------------------
// 1. Moc świateł w dużym akwarium (Big Aquarium Lights)
// -----------------------------------------------------------------------------
from(bucket: "mqtt")
  |> range(start: v.timeRangeStart, stop: v.timeRangeStop)
  |> filter(fn: (r) => r._measurement == "mqtt_consumer")
  |> filter(fn: (r) => r.topic == "zigbee2mqtt/Big Aquarium Lights")
  |> filter(fn: (r) => r._field == "power")
  |> aggregateWindow(every: v.windowPeriod, fn: mean, createEmpty: false)

// -----------------------------------------------------------------------------
// 2. Moc świateł w małym akwarium (Small Aquarium Lights)
// -----------------------------------------------------------------------------
from(bucket: "mqtt")
  |> range(start: v.timeRangeStart, stop: v.timeRangeStop)
  |> filter(fn: (r) => r._measurement == "mqtt_consumer")
  |> filter(fn: (r) => r.topic == "zigbee2mqtt/Small Aquarium Lights")
  |> filter(fn: (r) => r._field == "power")
  |> aggregateWindow(every: v.windowPeriod, fn: mean, createEmpty: false)

// -----------------------------------------------------------------------------
// 3. Moc obu świateł razem
// -----------------------------------------------------------------------------
from(bucket: "mqtt")
  |> range(start: v.timeRangeStart, stop: v.timeRangeStop)
  |> filter(fn: (r) => r._measurement == "mqtt_consumer")
  |> filter(fn: (r) => r.topic == "zigbee2mqtt/Big Aquarium Lights" or r.topic == "zigbee2mqtt/Small Aquarium Lights")
  |> filter(fn: (r) => r._field == "power")
  |> aggregateWindow(every: v.windowPeriod, fn: mean, createEmpty: false)

// -----------------------------------------------------------------------------
// 4. Zużycie energii świateł
// -----------------------------------------------------------------------------
from(bucket: "mqtt")
  |> range(start: v.timeRangeStart, stop: v.timeRangeStop)
  |> filter(fn: (r) => r._measurement == "mqtt_consumer")
  |> filter(fn: (r) => r.topic == "zigbee2mqtt/Big Aquarium Lights" or r.topic == "zigbee2mqtt/Small Aquarium Lights")
  |> filter(fn: (r) => r._field == "energy")
  |> aggregateWindow(every: v.windowPeriod, fn: last, createEmpty: false)

// -----------------------------------------------------------------------------
// 5. Napięcie i prąd świateł
// -----------------------------------------------------------------------------
from(bucket: "mqtt")
  |> range(start: v.timeRangeStart, stop: v.timeRangeStop)
  |> filter(fn: (r) => r._measurement == "mqtt_consumer")
  |> filter(fn: (r) => r.topic == "zigbee2mqtt/Big Aquarium Lights" or r.topic == "zigbee2mqtt/Small Aquarium Lights")
  |> filter(fn: (r) => r._field == "voltage" or r._field == "current")
  |> aggregateWindow(every: v.windowPeriod, fn: mean, createEmpty: false)

// -----------------------------------------------------------------------------
// 6. Wszystkie urządzenia akwariowe (filtry, grzałki, światła)
// -----------------------------------------------------------------------------
from(bucket: "mqtt")
  |> range(start: v.timeRangeStart, stop: v.timeRangeStop)
  |> filter(fn: (r) => r._measurement == "mqtt_consumer")
  |> filter(fn: (r) => r.topic =~ /zigbee2mqtt\/(Big|Small) Aquarium|Filter|Heater/)
  |> filter(fn: (r) => r._field == "power")
  |> aggregateWindow(every: v.windowPeriod, fn: mean, createEmpty: false)

// -----------------------------------------------------------------------------
// 7. Suma mocy wszystkich urządzeń akwariowych
// -----------------------------------------------------------------------------
from(bucket: "mqtt")
  |> range(start: v.timeRangeStart, stop: v.timeRangeStop)
  |> filter(fn: (r) => r._measurement == "mqtt_consumer")
  |> filter(fn: (r) => r.topic =~ /zigbee2mqtt\/(Big|Small) Aquarium|Filter|Heater/)
  |> filter(fn: (r) => r._field == "power")
  |> aggregateWindow(every: v.windowPeriod, fn: sum, createEmpty: false)

// -----------------------------------------------------------------------------
// 8. Jakość połączenia Zigbee urządzeń
// -----------------------------------------------------------------------------
from(bucket: "mqtt")
  |> range(start: v.timeRangeStart, stop: v.timeRangeStop)
  |> filter(fn: (r) => r._measurement == "mqtt_consumer")
  |> filter(fn: (r) => r.topic =~ /zigbee2mqtt\/(Big|Small) Aquarium|Filter|Heater/)
  |> filter(fn: (r) => r._field == "linkquality")
  |> aggregateWindow(every: v.windowPeriod, fn: mean, createEmpty: false)
