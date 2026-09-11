package portal

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"math"
	"net/http"
	"sort"
	"strings"
	"sync"
	"time"
)

const liveCacheTTL = 8 * time.Second

type liveCacheEntry struct {
	data       json.RawMessage
	observedAt time.Time
	fetchedAt  time.Time
}

type liveSource struct {
	prom  *promAPI
	now   func() time.Time
	mu    sync.Mutex
	cache map[string]liveCacheEntry
}

func newLiveSource(rawURL string, client *http.Client, now func() time.Time) (*liveSource, error) {
	prom, err := newPromAPI(rawURL, client)
	if err != nil {
		return nil, err
	}
	return &liveSource{prom: prom, now: now, cache: make(map[string]liveCacheEntry)}, nil
}

type liveFetch func(context.Context) (any, time.Time, error)

func (l *liveSource) get(ctx context.Context, key string) (json.RawMessage, sampleMeta, error) {
	fetch, maxAge, err := l.fetcher(key)
	if err != nil {
		return nil, sampleMeta{}, err
	}
	now := l.now().UTC()
	l.mu.Lock()
	cached, found := l.cache[key]
	l.mu.Unlock()
	if found && now.Sub(cached.fetchedAt) < liveCacheTTL {
		return cached.data, liveSampleMeta(now, cached.observedAt, maxAge, ""), nil
	}

	value, observedAt, fetchErr := fetch(ctx)
	if fetchErr != nil {
		if found {
			meta := liveSampleMeta(now, cached.observedAt, maxAge, fetchErr.Error())
			meta.Freshness = "stale"
			return cached.data, meta, nil
		}
		return nil, sampleMeta{}, fetchErr
	}
	data, err := json.Marshal(value)
	if err != nil {
		return nil, sampleMeta{}, err
	}
	if observedAt.IsZero() {
		observedAt = now
	}
	entry := liveCacheEntry{data: data, observedAt: observedAt, fetchedAt: now}
	l.mu.Lock()
	l.cache[key] = entry
	l.mu.Unlock()
	return data, liveSampleMeta(now, observedAt, maxAge, ""), nil
}

func (l *liveSource) fetcher(key string) (liveFetch, time.Duration, error) {
	switch key {
	case "overview":
		return l.fetchOverview, 35 * time.Second, nil
	case "topology":
		return l.fetchTopology, 70 * time.Second, nil
	case "nodes":
		return l.fetchNodes, 25 * time.Second, nil
	case "clients":
		return l.fetchClients, 25 * time.Second, nil
	case "tikv":
		return l.fetchTiKV, 35 * time.Second, nil
	case "ceph":
		return l.fetchCeph, 35 * time.Second, nil
	case "usage":
		return l.fetchUsage, 70 * time.Second, nil
	case "alerts":
		return l.fetchAlerts, 35 * time.Second, nil
	default:
		if strings.HasPrefix(key, "disks:") {
			nodeID := strings.TrimPrefix(key, "disks:")
			if _, ok := clusterDisks[nodeID]; !ok {
				return nil, 0, errNodeNotFound
			}
			return func(ctx context.Context) (any, time.Time, error) {
				return l.fetchDisks(ctx, nodeID)
			}, 25 * time.Second, nil
		}
	}
	return nil, 0, errors.New("unknown live endpoint")
}

func liveSampleMeta(now, observedAt time.Time, maxAge time.Duration, message string) sampleMeta {
	age := now.Sub(observedAt).Seconds()
	if age < 0 {
		age = 0
	}
	freshness := "fresh"
	if age > maxAge.Seconds() {
		freshness = "stale"
	}
	return sampleMeta{
		Source:      "prometheus",
		CollectedAt: observedAt.UTC().Format(time.RFC3339),
		AgeSeconds:  math.Round(age*10) / 10,
		Freshness:   freshness,
		Error:       message,
	}
}

func oldestTimestamp(batch map[string][]promSample) time.Time {
	var oldest time.Time
	for _, samples := range batch {
		for _, sample := range samples {
			if oldest.IsZero() || sample.Timestamp.Before(oldest) {
				oldest = sample.Timestamp
			}
		}
	}
	return oldest
}

func intPointer(value *float64) *int {
	if value == nil {
		return nil
	}
	result := int(math.Round(*value))
	return &result
}

func countUp(samples []promSample, job string) (int, int) {
	healthy, total := 0, 0
	for _, sample := range samples {
		if sample.Metric["job"] != job {
			continue
		}
		total++
		if sample.Value == 1 {
			healthy++
		}
	}
	return healthy, total
}

func componentCount(healthy, total int) map[string]any {
	return map[string]any{"healthy": healthy, "total": total}
}

func firstMetric(samples []promSample, label string) string {
	if len(samples) == 0 {
		return ""
	}
	return samples[0].Metric[label]
}

func (l *liveSource) fetchOverview(ctx context.Context) (any, time.Time, error) {
	batch, err := l.prom.batch(ctx, []namedQuery{
		{Name: "up", Expression: `up{job=~"juicefs-client|pd|tikv|node"}`},
		{Name: "jfsRead", Expression: `sum(rate(juicefs_fuse_read_size_bytes_sum[1m]))`},
		{Name: "jfsWrite", Expression: `sum(rate(juicefs_fuse_written_size_bytes_sum[1m]))`},
		{Name: "cephRead", Expression: `sum(rate(ceph_pool_rd_bytes{pool_id="3"}[1m]))`},
		{Name: "cephWrite", Expression: `sum(rate(ceph_pool_wr_bytes{pool_id="3"}[1m]))`},
		{Name: "networkRx", Expression: `sum(rate(node_network_receive_bytes_total{device!="lo"}[1m]))`},
		{Name: "networkTx", Expression: `sum(rate(node_network_transmit_bytes_total{device!="lo"}[1m]))`},
		{Name: "logicalUsed", Expression: `max(juicefs_used_space)`},
		{Name: "usedInodes", Expression: `max(juicefs_used_inodes)`},
		{Name: "poolRawUsed", Expression: `max(ceph_pool_stored_raw{pool_id="3"})`},
		{Name: "clusterTotal", Expression: `max(ceph_cluster_total_bytes)`},
		{Name: "clusterUsed", Expression: `max(ceph_cluster_total_used_raw_bytes)`},
		{Name: "cephHealth", Expression: `max(ceph_health_status)`},
		{Name: "mon", Expression: `ceph_mon_quorum_status`},
		{Name: "mgr", Expression: `ceph_mgr_status`},
		{Name: "osdUp", Expression: `ceph_osd_up`},
		{Name: "osdIn", Expression: `ceph_osd_in`},
		{Name: "pgClean", Expression: `max(ceph_pg_clean)`},
		{Name: "pgTotal", Expression: `max(ceph_pg_total)`},
	})
	if err != nil {
		return nil, time.Time{}, err
	}

	jfsHealthy, jfsTotal := countUp(batch["up"], "juicefs-client")
	pdHealthy, pdTotal := countUp(batch["up"], "pd")
	tikvHealthy, tikvTotal := countUp(batch["up"], "tikv")
	nodeHealthy, nodeTotal := countUp(batch["up"], "node")
	monHealthy := 0
	for _, sample := range batch["mon"] {
		if sample.Value == 1 {
			monHealthy++
		}
	}
	mgrHealthy := len(batch["mgr"])
	osdHealthy := 0
	for _, sample := range batch["osdUp"] {
		if sample.Value == 1 {
			osdHealthy++
		}
	}
	pgClean, _ := scalar(batch["pgClean"])
	pgTotal, _ := scalar(batch["pgTotal"])
	cephHealth, _ := scalar(batch["cephHealth"])
	clusterTotal, _ := scalar(batch["clusterTotal"])
	clusterUsed, _ := scalar(batch["clusterUsed"])
	var clusterAvailable *float64
	if clusterTotal != nil && clusterUsed != nil {
		value := math.Max(0, *clusterTotal-*clusterUsed)
		clusterAvailable = &value
	}
	healthy := jfsHealthy == 1 && jfsTotal == 1 && pdHealthy == 3 && pdTotal == 3 &&
		tikvHealthy == 3 && tikvTotal == 3 && nodeHealthy == 4 && nodeTotal == 4 &&
		cephHealth != nil && *cephHealth == 0 && osdHealthy == 6 &&
		pgClean != nil && pgTotal != nil && *pgClean == *pgTotal
	activeAlerts := 0
	if !healthy {
		activeAlerts = 1
	}

	value := map[string]any{
		"clusterId": "juicefs-prod",
		"health":    map[bool]string{true: "healthy", false: "degraded"}[healthy],
		"clients": map[string]any{
			"online": jfsHealthy,
			"total":  jfsTotal,
		},
		"bandwidth": map[string]any{},
		"usage":     map[string]any{},
		"components": map[string]any{
			"pd":   componentCount(pdHealthy, pdTotal),
			"tikv": componentCount(tikvHealthy, tikvTotal),
			"node": componentCount(nodeHealthy, nodeTotal),
			"mon":  componentCount(monHealthy, len(batch["mon"])),
			"mgr":  componentCount(mgrHealthy, len(batch["mgr"])),
			"osd":  componentCount(osdHealthy, len(batch["osdUp"])),
			"pg":   map[string]any{"clean": intPointer(pgClean), "total": intPointer(pgTotal)},
		},
		"activeAlerts": activeAlerts,
	}
	bandwidth := value["bandwidth"].(map[string]any)
	bandwidth["juicefsLogicalReadBps"], _ = scalar(batch["jfsRead"])
	bandwidth["juicefsLogicalWriteBps"], _ = scalar(batch["jfsWrite"])
	bandwidth["cephPhysicalReadBps"], _ = scalar(batch["cephRead"])
	bandwidth["cephPhysicalWriteBps"], _ = scalar(batch["cephWrite"])
	bandwidth["nodeNetworkRxBps"], _ = scalar(batch["networkRx"])
	bandwidth["nodeNetworkTxBps"], _ = scalar(batch["networkTx"])
	usage := value["usage"].(map[string]any)
	usage["logicalUsedBytes"], _ = scalar(batch["logicalUsed"])
	usage["usedInodes"], _ = scalar(batch["usedInodes"])
	usage["poolRawUsedBytes"], _ = scalar(batch["poolRawUsed"])
	usage["clusterRawAvailableBytes"] = clusterAvailable
	return value, oldestTimestamp(batch), nil
}

func (l *liveSource) fetchNodes(ctx context.Context) (any, time.Time, error) {
	batch, err := l.prom.batch(ctx, []namedQuery{
		{Name: "up", Expression: `up{job="node"}`},
		{Name: "cpu", Expression: `100 * (1 - avg by (node) (rate(node_cpu_seconds_total{mode="idle"}[1m])))`},
		{Name: "memory", Expression: `max by (node) (node_memory_MemAvailable_bytes)`},
		{Name: "rx", Expression: `sum by (node) (rate(node_network_receive_bytes_total{device!="lo"}[1m]))`},
		{Name: "tx", Expression: `sum by (node) (rate(node_network_transmit_bytes_total{device!="lo"}[1m]))`},
	})
	if err != nil {
		return nil, time.Time{}, err
	}
	up := sampleMap(batch["up"], "node")
	cpu := sampleMap(batch["cpu"], "node")
	memory := sampleMap(batch["memory"], "node")
	rx := sampleMap(batch["rx"], "node")
	tx := sampleMap(batch["tx"], "node")
	now := l.now().UTC()
	nodes := make([]map[string]any, 0, len(clusterNodes))
	for _, definition := range clusterNodes {
		upValue := sampleValue(up, definition.ID)
		observed := now
		if sample, ok := up[definition.ID]; ok {
			observed = sample.Timestamp
		}
		nodes = append(nodes, map[string]any{
			"id":                   definition.ID,
			"hostname":             definition.Hostname,
			"ip":                   definition.IP,
			"roles":                definition.Roles,
			"status":               boolStatus(upValue),
			"cpuPercent":           rounded(sampleValue(cpu, definition.ID), 1),
			"memoryAvailableBytes": sampleValue(memory, definition.ID),
			"networkRxBps":         sampleValue(rx, definition.ID),
			"networkTxBps":         sampleValue(tx, definition.ID),
			"sample":               liveSampleMeta(now, observed, 25*time.Second, ""),
		})
	}
	return nodes, oldestTimestamp(batch), nil
}

func (l *liveSource) fetchDisks(ctx context.Context, nodeID string) (any, time.Time, error) {
	selector := fmt.Sprintf(`{node=%q,device=~"nvme[0-3]n1"}`, nodeID)
	controllerSelector := fmt.Sprintf(`{node=%q}`, nodeID)
	batch, err := l.prom.batch(ctx, []namedQuery{
		{Name: "up", Expression: fmt.Sprintf(`up{job="node",node=%q}`, nodeID)},
		{Name: "info", Expression: "node_disk_info" + selector},
		{Name: "readBps", Expression: `sum by (device) (rate(node_disk_read_bytes_total` + selector + `[1m]))`},
		{Name: "writeBps", Expression: `sum by (device) (rate(node_disk_written_bytes_total` + selector + `[1m]))`},
		{Name: "readIOPS", Expression: `sum by (device) (rate(node_disk_reads_completed_total` + selector + `[1m]))`},
		{Name: "writeIOPS", Expression: `sum by (device) (rate(node_disk_writes_completed_total` + selector + `[1m]))`},
		{Name: "latency", Expression: `(sum by (device) (rate(node_disk_read_time_seconds_total` + selector + `[1m]) + rate(node_disk_write_time_seconds_total` + selector + `[1m]))) / clamp_min(sum by (device) (rate(node_disk_reads_completed_total` + selector + `[1m]) + rate(node_disk_writes_completed_total` + selector + `[1m])), 0.000001)`},
		{Name: "queue", Expression: `sum by (device) (rate(node_disk_io_time_weighted_seconds_total` + selector + `[1m]))`},
		{Name: "util", Expression: `100 * sum by (device) (rate(node_disk_io_time_seconds_total` + selector + `[1m]))`},
		{Name: "temperature", Expression: "jfsportal_nvme_temperature_celsius" + controllerSelector},
		{Name: "spare", Expression: "jfsportal_nvme_available_spare_ratio" + controllerSelector},
		{Name: "used", Expression: "jfsportal_nvme_percentage_used_ratio" + controllerSelector},
		{Name: "media", Expression: "jfsportal_nvme_media_errors_total" + controllerSelector},
		{Name: "unsafe", Expression: "jfsportal_nvme_unsafe_shutdowns_total" + controllerSelector},
		{Name: "critical", Expression: "jfsportal_nvme_critical_warning" + controllerSelector},
	})
	if err != nil {
		return nil, time.Time{}, err
	}
	info := sampleMap(batch["info"], "device")
	readBps := sampleMap(batch["readBps"], "device")
	writeBps := sampleMap(batch["writeBps"], "device")
	readIOPS := sampleMap(batch["readIOPS"], "device")
	writeIOPS := sampleMap(batch["writeIOPS"], "device")
	latency := sampleMap(batch["latency"], "device")
	queue := sampleMap(batch["queue"], "device")
	util := sampleMap(batch["util"], "device")
	temperature := sampleMap(batch["temperature"], "device")
	spare := sampleMap(batch["spare"], "device")
	used := sampleMap(batch["used"], "device")
	media := sampleMap(batch["media"], "device")
	unsafe := sampleMap(batch["unsafe"], "device")
	critical := sampleMap(batch["critical"], "device")
	now := l.now().UTC()
	upValue, upAt := scalar(batch["up"])
	if upAt.IsZero() {
		upAt = now
	}
	disks := make([]map[string]any, 0, len(clusterDisks[nodeID]))
	for _, definition := range clusterDisks[nodeID] {
		infoSample := info[definition.Device]
		criticalValue := sampleValue(critical, definition.Controller)
		mediaValue := sampleValue(media, definition.Controller)
		status := boolStatus(upValue)
		if status == "healthy" && ((criticalValue != nil && *criticalValue > 0) || (mediaValue != nil && *mediaValue > 0)) {
			status = "warning"
		}
		disks = append(disks, map[string]any{
			"id":                  nodeID + "-" + definition.Device,
			"device":              definition.Device,
			"controller":          definition.Controller,
			"purpose":             definition.Purpose,
			"mountpoint":          definition.Mountpoint,
			"cephDaemon":          definition.CephDaemon,
			"sizeBytes":           definition.SizeBytes,
			"model":               infoSample.Metric["model"],
			"serial":              infoSample.Metric["serial"],
			"firmware":            infoSample.Metric["revision"],
			"pciePath":            infoSample.Metric["path"],
			"status":              status,
			"readBps":             sampleValue(readBps, definition.Device),
			"writeBps":            sampleValue(writeBps, definition.Device),
			"readIops":            sampleValue(readIOPS, definition.Device),
			"writeIops":           sampleValue(writeIOPS, definition.Device),
			"latencySeconds":      sampleValue(latency, definition.Device),
			"queueDepth":          sampleValue(queue, definition.Device),
			"utilPercent":         rounded(sampleValue(util, definition.Device), 1),
			"temperatureC":        sampleValue(temperature, definition.Controller),
			"availableSpareRatio": sampleValue(spare, definition.Controller),
			"percentageUsedRatio": sampleValue(used, definition.Controller),
			"mediaErrors":         sampleValue(media, definition.Controller),
			"unsafeShutdowns":     sampleValue(unsafe, definition.Controller),
			"criticalWarning":     criticalValue,
			"sample":              liveSampleMeta(now, upAt, 25*time.Second, ""),
		})
	}
	return disks, oldestTimestamp(batch), nil
}

func (l *liveSource) fetchTopology(ctx context.Context) (any, time.Time, error) {
	batch, err := l.prom.batch(ctx, []namedQuery{
		{Name: "up", Expression: `up{job=~"juicefs-client|pd|tikv"}`},
		{Name: "pdLeader", Expression: `etcd_server_is_leader{job="pd"}`},
		{Name: "mgr", Expression: `ceph_mgr_status`},
		{Name: "mon", Expression: `ceph_mon_quorum_status`},
		{Name: "cephHealth", Expression: `max(ceph_health_status)`},
		{Name: "osdUp", Expression: `ceph_osd_up`},
		{Name: "osdIn", Expression: `ceph_osd_in`},
		{Name: "diskCritical", Expression: `jfsportal_nvme_critical_warning`},
	})
	if err != nil {
		return nil, time.Time{}, err
	}
	up := sampleMap(batch["up"], "job", "node")
	osdUp := sampleMap(batch["osdUp"], "ceph_daemon")
	osdIn := sampleMap(batch["osdIn"], "ceph_daemon")
	diskCritical := sampleMap(batch["diskCritical"], "node", "device")
	pdHealthy, pdTotal := countUp(batch["up"], "pd")
	cephHealth, _ := scalar(batch["cephHealth"])
	cephStatus := "unknown"
	if cephHealth != nil {
		cephStatus = map[bool]string{true: "healthy", false: "warning"}[*cephHealth == 0]
	}
	leader := "unknown"
	for _, sample := range batch["pdLeader"] {
		if sample.Value == 1 {
			leader = sample.Metric["node"]
			break
		}
	}
	activeMgr := "unknown"
	for _, sample := range batch["mgr"] {
		if sample.Value == 1 {
			activeMgr = strings.TrimPrefix(sample.Metric["ceph_daemon"], "mgr.")
			break
		}
	}
	nodes := []map[string]any{
		{"id": "client-157", "kind": "client", "label": "JuiceFS client 157", "status": boolStatus(sampleValue(up, "juicefs-client\x00157"))},
		{"id": "volume-prod", "kind": "volume", "label": "juicefs-prod", "status": boolStatus(sampleValue(up, "juicefs-client\x00157"))},
		{"id": "pd-cluster", "kind": "pd", "label": fmt.Sprintf("PD %d/%d", pdHealthy, pdTotal), "status": map[bool]string{true: "healthy", false: "warning"}[pdHealthy == 3 && pdTotal == 3], "detail": "leader: " + leader},
		{"id": "ceph-control", "kind": "ceph", "label": "Ceph MON / MGR", "status": cephStatus, "detail": "active mgr: " + activeMgr},
		{"id": "ceph-pool", "kind": "pool", "label": "juicefs-data · EC 4+2", "status": cephStatus},
	}
	edges := []map[string]string{
		{"from": "client-157", "to": "volume-prod", "relation": "mounts"},
		{"from": "volume-prod", "to": "pd-cluster", "relation": "metadata"},
		{"from": "volume-prod", "to": "ceph-control", "relation": "object API"},
		{"from": "ceph-control", "to": "ceph-pool", "relation": "serves"},
	}
	for _, nodeID := range []string{"150", "151", "152"} {
		id := "tikv-" + nodeID
		nodes = append(nodes, map[string]any{"id": id, "kind": "tikv", "label": "TiKV " + nodeID, "status": boolStatus(sampleValue(up, "tikv\x00"+nodeID))})
		edges = append(edges, map[string]string{"from": "pd-cluster", "to": id, "relation": "store"})
	}
	for nodeID, definitions := range clusterDisks {
		for _, definition := range definitions {
			if definition.CephDaemon == "" {
				continue
			}
			osdStatus := "unknown"
			upValue := sampleValue(osdUp, definition.CephDaemon)
			inValue := sampleValue(osdIn, definition.CephDaemon)
			if upValue != nil && inValue != nil {
				osdStatus = map[bool]string{true: "healthy", false: "warning"}[*upValue == 1 && *inValue == 1]
			}
			diskStatus := "healthy"
			if warning := sampleValue(diskCritical, nodeID+"\x00"+definition.Controller); warning == nil {
				diskStatus = "unknown"
			} else if *warning != 0 {
				diskStatus = "warning"
			}
			diskID := "disk-" + nodeID + "-" + definition.Device
			nodes = append(nodes,
				map[string]any{"id": definition.CephDaemon, "kind": "osd", "label": strings.ToUpper(definition.CephDaemon), "status": osdStatus, "detail": "node " + nodeID},
				map[string]any{"id": diskID, "kind": "disk", "label": nodeID + " / " + definition.Device, "status": diskStatus},
			)
			edges = append(edges,
				map[string]string{"from": "ceph-pool", "to": definition.CephDaemon, "relation": "places"},
				map[string]string{"from": definition.CephDaemon, "to": diskID, "relation": "uses"},
			)
		}
	}
	sort.Slice(nodes, func(i, j int) bool { return nodes[i]["id"].(string) < nodes[j]["id"].(string) })
	return map[string]any{"nodes": nodes, "edges": edges}, oldestTimestamp(batch), nil
}

func (l *liveSource) fetchClients(ctx context.Context) (any, time.Time, error) {
	batch, err := l.prom.batch(ctx, []namedQuery{
		{Name: "up", Expression: `up{job="juicefs-client"}`},
		{Name: "uptime", Expression: `max(juicefs_uptime)`},
		{Name: "readBps", Expression: `sum(rate(juicefs_fuse_read_size_bytes_sum[1m]))`},
		{Name: "writeBps", Expression: `sum(rate(juicefs_fuse_written_size_bytes_sum[1m]))`},
		{Name: "readIOPS", Expression: `sum(rate(juicefs_fuse_read_size_bytes_count[1m]))`},
		{Name: "writeIOPS", Expression: `sum(rate(juicefs_fuse_written_size_bytes_count[1m]))`},
		{Name: "fuseLatency", Expression: `sum(rate(juicefs_fuse_ops_durations_histogram_seconds_sum[1m])) / clamp_min(sum(rate(juicefs_fuse_ops_durations_histogram_seconds_count[1m])), 0.000001)`},
		{Name: "getBps", Expression: `sum(rate(juicefs_object_request_data_bytes{method="GET"}[1m]))`},
		{Name: "putBps", Expression: `sum(rate(juicefs_object_request_data_bytes{method="PUT"}[1m]))`},
		{Name: "getRate", Expression: `sum(rate(juicefs_object_request_durations_histogram_seconds_count{method="GET"}[1m]))`},
		{Name: "putRate", Expression: `sum(rate(juicefs_object_request_durations_histogram_seconds_count{method="PUT"}[1m]))`},
		{Name: "getLatency", Expression: `sum(rate(juicefs_object_request_durations_histogram_seconds_sum{method="GET"}[1m])) / clamp_min(sum(rate(juicefs_object_request_durations_histogram_seconds_count{method="GET"}[1m])), 0.000001)`},
		{Name: "putLatency", Expression: `sum(rate(juicefs_object_request_durations_histogram_seconds_sum{method="PUT"}[1m])) / clamp_min(sum(rate(juicefs_object_request_durations_histogram_seconds_count{method="PUT"}[1m])), 0.000001)`},
		{Name: "cacheBytes", Expression: `max(juicefs_blockcache_bytes)`},
		{Name: "cacheHit", Expression: `sum(rate(juicefs_blockcache_hit_bytes[5m])) / clamp_min(sum(rate(juicefs_blockcache_hit_bytes[5m]) + rate(juicefs_blockcache_miss_bytes[5m])), 0.000001)`},
		{Name: "cacheEvicts", Expression: `sum(rate(juicefs_blockcache_evicts[5m]))`},
		{Name: "cacheDrops", Expression: `sum(rate(juicefs_blockcache_drops[5m]))`},
		{Name: "stagingBlocks", Expression: `sum(juicefs_staging_blocks)`},
		{Name: "stagingBytes", Expression: `sum(juicefs_staging_block_bytes)`},
		{Name: "bufferBytes", Expression: `sum(juicefs_used_buffer_size_bytes)`},
		{Name: "cpu", Expression: `sum(rate(juicefs_process_cpu_seconds_total[1m]))`},
		{Name: "rss", Expression: `sum(juicefs_process_resident_memory_bytes)`},
	})
	if err != nil {
		return nil, time.Time{}, err
	}
	upValue, _ := scalar(batch["up"])
	version := firstMetric(batch["uptime"], "juicefs_version")
	if version == "" {
		version = "unknown"
	}
	readBps, _ := scalar(batch["readBps"])
	writeBps, _ := scalar(batch["writeBps"])
	readIOPS, _ := scalar(batch["readIOPS"])
	writeIOPS, _ := scalar(batch["writeIOPS"])
	uptime, _ := scalar(batch["uptime"])
	client := map[string]any{
		"id":            "client-157-juicefs-prod",
		"nodeId":        "157",
		"hostname":      "oneasia-c1-cpu-node10",
		"volume":        "juicefs-prod",
		"mountpoint":    "/mnt/juicefs",
		"version":       version,
		"status":        boolStatus(upValue),
		"uptimeSeconds": uptime,
		"mountOptions":  map[string]any{"maxUploads": 150, "cacheSizeMiB": 0, "maxFuseIo": "256K"},
		"io": map[string]any{
			"readBps": readBps, "writeBps": writeBps,
			"readIops": readIOPS, "writeIops": writeIOPS,
			"averageFuseLatencySeconds": firstScalar(batch["fuseLatency"]),
		},
		"object": map[string]any{
			"getBps": firstScalar(batch["getBps"]), "putBps": firstScalar(batch["putBps"]),
			"getRate": firstScalar(batch["getRate"]), "putRate": firstScalar(batch["putRate"]),
			"getLatencySeconds": firstScalar(batch["getLatency"]), "putLatencySeconds": firstScalar(batch["putLatency"]),
		},
		"cache": map[string]any{
			"hitRatioBytes": firstScalar(batch["cacheHit"]), "bytes": firstScalar(batch["cacheBytes"]),
			"evictsPerSecond": firstScalar(batch["cacheEvicts"]), "dropsPerSecond": firstScalar(batch["cacheDrops"]),
		},
		"writeback": map[string]any{
			"stagingBlocks": firstScalar(batch["stagingBlocks"]), "stagingBytes": firstScalar(batch["stagingBytes"]),
			"bufferBytes": firstScalar(batch["bufferBytes"]),
		},
		"process": map[string]any{"cpuCores": firstScalar(batch["cpu"]), "rssBytes": firstScalar(batch["rss"])},
	}
	return []map[string]any{client}, oldestTimestamp(batch), nil
}

func firstScalar(samples []promSample) *float64 {
	value, _ := scalar(samples)
	return value
}

func (l *liveSource) fetchTiKV(ctx context.Context) (any, time.Time, error) {
	batch, err := l.prom.batch(ctx, []namedQuery{
		{Name: "pdUp", Expression: `up{job="pd"}`},
		{Name: "pdLeader", Expression: `etcd_server_is_leader{job="pd"}`},
		{Name: "tikvUp", Expression: `up{job="tikv"}`},
		{Name: "regions", Expression: `sum by (node, type) (tikv_raftstore_region_count{type=~"leader|region"})`},
		{Name: "schedulerLatency", Expression: `sum(rate(tikv_scheduler_command_duration_seconds_sum[1m])) / clamp_min(sum(rate(tikv_scheduler_command_duration_seconds_count[1m])), 0.000001)`},
		{Name: "raftCommitLatency", Expression: `sum(rate(tikv_raftstore_commit_log_duration_seconds_sum[1m])) / clamp_min(sum(rate(tikv_raftstore_commit_log_duration_seconds_count[1m])), 0.000001)`},
		{Name: "pendingCompaction", Expression: `sum(tikv_engine_pending_compaction_bytes)`},
		{Name: "l0Files", Expression: `sum(tikv_engine_num_files_at_level{level="0"})`},
		{Name: "writeStall", Expression: `max(tikv_engine_write_stall)`},
		{Name: "cpu", Expression: `sum by (node) (rate(process_cpu_seconds_total{job="tikv"}[1m]))`},
		{Name: "rss", Expression: `sum by (node) (process_resident_memory_bytes{job="tikv"})`},
	})
	if err != nil {
		return nil, time.Time{}, err
	}
	pdHealthy, pdTotal := countUp(batch["pdUp"], "pd")
	leader := "unknown"
	for _, sample := range batch["pdLeader"] {
		if sample.Value == 1 {
			leader = sample.Metric["node"]
		}
	}
	up := sampleMap(batch["tikvUp"], "node")
	regions := sampleMap(batch["regions"], "node", "type")
	cpu := sampleMap(batch["cpu"], "node")
	rss := sampleMap(batch["rss"], "node")
	stores := make([]map[string]any, 0, 3)
	for _, nodeID := range []string{"150", "151", "152"} {
		stores = append(stores, map[string]any{
			"id": nodeID, "nodeId": nodeID, "state": strings.ToUpper(boolStatus(sampleValue(up, nodeID))),
			"leaderCount": sampleValue(regions, nodeID+"\x00leader"), "regionCount": sampleValue(regions, nodeID+"\x00region"),
			"cpuCores": sampleValue(cpu, nodeID), "rssBytes": sampleValue(rss, nodeID),
		})
	}
	stall, _ := scalar(batch["writeStall"])
	return map[string]any{
		"pd":                       map[string]any{"leader": leader, "members": pdTotal, "healthyMembers": pdHealthy},
		"stores":                   stores,
		"schedulerLatencySeconds":  firstScalar(batch["schedulerLatency"]),
		"raftCommitLatencySeconds": firstScalar(batch["raftCommitLatency"]),
		"pendingCompactionBytes":   firstScalar(batch["pendingCompaction"]),
		"l0Files":                  firstScalar(batch["l0Files"]),
		"writeStall":               stall != nil && *stall > 0,
	}, oldestTimestamp(batch), nil
}

func (l *liveSource) fetchCeph(ctx context.Context) (any, time.Time, error) {
	batch, err := l.prom.batch(ctx, []namedQuery{
		{Name: "health", Expression: `max(ceph_health_status)`},
		{Name: "mon", Expression: `ceph_mon_quorum_status`},
		{Name: "mgr", Expression: `ceph_mgr_status`},
		{Name: "osdUp", Expression: `ceph_osd_up`},
		{Name: "osdIn", Expression: `ceph_osd_in`},
		{Name: "pgClean", Expression: `max(ceph_pg_clean)`},
		{Name: "pgTotal", Expression: `max(ceph_pg_total)`},
		{Name: "poolStored", Expression: `max(ceph_pool_stored{pool_id="3"})`},
		{Name: "poolRaw", Expression: `max(ceph_pool_stored_raw{pool_id="3"})`},
		{Name: "poolAvailable", Expression: `max(ceph_pool_max_avail{pool_id="3"})`},
		{Name: "readBps", Expression: `sum(rate(ceph_pool_rd_bytes{pool_id="3"}[1m]))`},
		{Name: "writeBps", Expression: `sum(rate(ceph_pool_wr_bytes{pool_id="3"}[1m]))`},
		{Name: "readIOPS", Expression: `sum(rate(ceph_pool_rd{pool_id="3"}[1m]))`},
		{Name: "writeIOPS", Expression: `sum(rate(ceph_pool_wr{pool_id="3"}[1m]))`},
		{Name: "recoveryBps", Expression: `sum(rate(ceph_osd_recovery_bytes[1m]))`},
		{Name: "recovering", Expression: `max(ceph_pg_recovering)`},
		{Name: "backfilling", Expression: `max(ceph_pg_backfilling)`},
		{Name: "scrubbing", Expression: `max(ceph_pg_scrubbing)`},
		{Name: "deep", Expression: `max(ceph_pg_deep)`},
		{Name: "applyLatency", Expression: `avg(ceph_osd_apply_latency_ms) / 1000`},
		{Name: "commitLatency", Expression: `avg(ceph_osd_commit_latency_ms) / 1000`},
	})
	if err != nil {
		return nil, time.Time{}, err
	}
	healthValue, _ := scalar(batch["health"])
	health := "UNKNOWN"
	if healthValue != nil {
		switch int(*healthValue) {
		case 0:
			health = "HEALTH_OK"
		case 1:
			health = "HEALTH_WARN"
		default:
			health = "HEALTH_ERR"
		}
	}
	monQuorum := 0
	for _, sample := range batch["mon"] {
		if sample.Value == 1 {
			monQuorum++
		}
	}
	activeMgr := "unknown"
	standbys := []string{}
	for _, sample := range batch["mgr"] {
		name := strings.TrimPrefix(sample.Metric["ceph_daemon"], "mgr.")
		if sample.Value == 1 {
			activeMgr = name
		} else {
			standbys = append(standbys, name)
		}
	}
	sort.Strings(standbys)
	osdUp, osdIn := 0, 0
	for _, sample := range batch["osdUp"] {
		if sample.Value == 1 {
			osdUp++
		}
	}
	for _, sample := range batch["osdIn"] {
		if sample.Value == 1 {
			osdIn++
		}
	}
	pgClean := firstScalar(batch["pgClean"])
	pgTotal := firstScalar(batch["pgTotal"])
	var nonClean *int
	if pgClean != nil && pgTotal != nil {
		value := int(math.Max(0, *pgTotal-*pgClean))
		nonClean = &value
	}
	return map[string]any{
		"health":    health,
		"monQuorum": monQuorum,
		"mgr":       map[string]any{"active": activeMgr, "standbys": standbys},
		"osd":       map[string]any{"up": osdUp, "in": osdIn, "total": len(batch["osdUp"])},
		"pg":        map[string]any{"clean": intPointer(pgClean), "total": intPointer(pgTotal), "nonClean": nonClean},
		"pool": map[string]any{
			"name": "juicefs-data", "profile": "EC 4+2",
			"storedBytes": firstScalar(batch["poolStored"]), "rawUsedBytes": firstScalar(batch["poolRaw"]),
			"maxAvailableBytes": firstScalar(batch["poolAvailable"]),
			"readBps":           firstScalar(batch["readBps"]), "writeBps": firstScalar(batch["writeBps"]),
			"readIops": firstScalar(batch["readIOPS"]), "writeIops": firstScalar(batch["writeIOPS"]),
		},
		"recoveryBps":   firstScalar(batch["recoveryBps"]),
		"recoveringPgs": firstScalar(batch["recovering"]), "backfillingPgs": firstScalar(batch["backfilling"]),
		"scrubbingPgs": firstScalar(batch["scrubbing"]), "deepScrubbingPgs": firstScalar(batch["deep"]),
		"applyLatencySeconds": firstScalar(batch["applyLatency"]), "commitLatencySeconds": firstScalar(batch["commitLatency"]),
	}, oldestTimestamp(batch), nil
}

func (l *liveSource) fetchUsage(ctx context.Context) (any, time.Time, error) {
	batch, err := l.prom.batch(ctx, []namedQuery{
		{Name: "logical", Expression: `max(juicefs_used_space)`},
		{Name: "inodes", Expression: `max(juicefs_used_inodes)`},
		{Name: "stored", Expression: `max(ceph_pool_stored{pool_id="3"})`},
		{Name: "poolRaw", Expression: `max(ceph_pool_stored_raw{pool_id="3"})`},
		{Name: "poolAvailable", Expression: `max(ceph_pool_max_avail{pool_id="3"})`},
		{Name: "clusterTotal", Expression: `max(ceph_cluster_total_bytes)`},
		{Name: "clusterUsed", Expression: `max(ceph_cluster_total_used_raw_bytes)`},
	})
	if err != nil {
		return nil, time.Time{}, err
	}
	clusterTotal := firstScalar(batch["clusterTotal"])
	clusterUsed := firstScalar(batch["clusterUsed"])
	var clusterAvailable *float64
	if clusterTotal != nil && clusterUsed != nil {
		value := math.Max(0, *clusterTotal-*clusterUsed)
		clusterAvailable = &value
	}
	return map[string]any{
		"volume":  map[string]any{"name": "juicefs-prod", "logicalUsedBytes": firstScalar(batch["logical"]), "usedInodes": firstScalar(batch["inodes"])},
		"pool":    map[string]any{"name": "juicefs-data", "storedBytes": firstScalar(batch["stored"]), "rawUsedBytes": firstScalar(batch["poolRaw"]), "maxAvailableBytes": firstScalar(batch["poolAvailable"])},
		"cluster": map[string]any{"rawUsedBytes": clusterUsed, "rawAvailableBytes": clusterAvailable, "rawTotalBytes": clusterTotal},
	}, oldestTimestamp(batch), nil
}

func (l *liveSource) fetchAlerts(ctx context.Context) (any, time.Time, error) {
	batch, err := l.prom.batch(ctx, []namedQuery{
		{Name: "up", Expression: `up{job=~"juicefs-client|pd|tikv|node"}`},
		{Name: "cephHealth", Expression: `max(ceph_health_status)`},
		{Name: "pgNonClean", Expression: `max(ceph_pg_total) - max(ceph_pg_clean)`},
		{Name: "osdDown", Expression: `count(ceph_osd_up == 0)`},
		{Name: "critical", Expression: `jfsportal_nvme_critical_warning != 0`},
		{Name: "temperature", Expression: `jfsportal_nvme_temperature_celsius >= 70`},
	})
	if err != nil {
		return nil, time.Time{}, err
	}
	now := l.now().UTC().Format(time.RFC3339)
	alerts := []map[string]any{}
	for _, sample := range batch["up"] {
		if sample.Value == 1 {
			continue
		}
		alerts = append(alerts, liveAlert("critical", sample.Metric["job"]+":"+sample.Metric["instance"], "采集目标不可用", now))
	}
	if value := firstScalar(batch["cephHealth"]); value != nil && *value != 0 {
		alerts = append(alerts, liveAlert("critical", "ceph", "Ceph集群健康状态异常", now))
	}
	if value := firstScalar(batch["pgNonClean"]); value != nil && *value > 0 {
		alerts = append(alerts, liveAlert("warning", "ceph:pg", fmt.Sprintf("存在%.0f个非clean PG", *value), now))
	}
	if value := firstScalar(batch["osdDown"]); value != nil && *value > 0 {
		alerts = append(alerts, liveAlert("critical", "ceph:osd", fmt.Sprintf("存在%.0f个Down OSD", *value), now))
	}
	for _, sample := range batch["critical"] {
		alerts = append(alerts, liveAlert("critical", sample.Metric["node"]+":"+sample.Metric["device"], "NVMe critical warning非零", now))
	}
	for _, sample := range batch["temperature"] {
		alerts = append(alerts, liveAlert("warning", sample.Metric["node"]+":"+sample.Metric["device"], fmt.Sprintf("NVMe温度%.0f°C", sample.Value), now))
	}
	return alerts, oldestTimestamp(batch), nil
}

func liveAlert(severity, object, summary, now string) map[string]any {
	return map[string]any{
		"id": severity + ":" + object, "severity": severity, "objectRef": object,
		"summary": summary, "activeSince": now, "updatedAt": now, "source": "prometheus", "status": "active",
	}
}

var liveTimeseriesQueries = map[string]string{
	"jfs.fuse.read_bps":      `sum(rate(juicefs_fuse_read_size_bytes_sum[1m]))`,
	"jfs.fuse.write_bps":     `sum(rate(juicefs_fuse_written_size_bytes_sum[1m]))`,
	"ceph.pool.read_bps":     `sum(rate(ceph_pool_rd_bytes{pool_id="3"}[1m]))`,
	"ceph.pool.write_bps":    `sum(rate(ceph_pool_wr_bytes{pool_id="3"}[1m]))`,
	"node.network.rx_bps":    `sum(rate(node_network_receive_bytes_total{device!="lo"}[1m]))`,
	"node.network.tx_bps":    `sum(rate(node_network_transmit_bytes_total{device!="lo"}[1m]))`,
	"tikv.scheduler.latency": `sum(rate(tikv_scheduler_command_duration_seconds_sum[1m])) / clamp_min(sum(rate(tikv_scheduler_command_duration_seconds_count[1m])), 0.000001)`,
}

func (l *liveSource) fetchTimeseries(ctx context.Context, metric string, from, to time.Time, step int) (any, time.Time, error) {
	expression, ok := liveTimeseriesQueries[metric]
	if !ok {
		return nil, time.Time{}, errors.New("metric is not whitelisted")
	}
	series, err := l.prom.queryRange(ctx, expression, from, to, step)
	if err != nil {
		return nil, time.Time{}, err
	}
	points := [][2]float64{}
	if len(series) > 0 {
		points = series[0].Points
	}
	return map[string]any{
		"metric": metric, "from": from.Format(time.RFC3339), "to": to.Format(time.RFC3339), "step": step, "points": points,
	}, l.now().UTC(), nil
}
