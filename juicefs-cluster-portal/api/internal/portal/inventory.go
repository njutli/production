package portal

type nodeDefinition struct {
	ID       string
	Hostname string
	IP       string
	Roles    []string
}

type diskDefinition struct {
	NodeID     string
	Device     string
	Controller string
	SizeBytes  uint64
	Purpose    string
	Mountpoint string
	CephDaemon string
}

var clusterNodes = []nodeDefinition{
	{ID: "150", Hostname: "ceph-node1", IP: "10.20.1.150", Roles: []string{"PD", "TiKV", "MON", "MGR", "OSD"}},
	{ID: "151", Hostname: "ceph-node2", IP: "10.20.1.151", Roles: []string{"PD", "TiKV", "MON", "MGR", "OSD"}},
	{ID: "152", Hostname: "ceph-node3", IP: "10.20.1.152", Roles: []string{"PD", "TiKV", "MON", "OSD", "Portal"}},
	{ID: "157", Hostname: "oneasia-c1-cpu-node10", IP: "10.20.1.157", Roles: []string{"JuiceFS client"}},
}

var clusterDisks = map[string][]diskDefinition{
	"150": {
		{NodeID: "150", Device: "nvme0n1", Controller: "nvme0", SizeBytes: 960197124096, Purpose: "system"},
		{NodeID: "150", Device: "nvme1n1", Controller: "nvme1", SizeBytes: 960197124096, Purpose: "TiKV KV", Mountpoint: "/mnt/jfs-tikv"},
		{NodeID: "150", Device: "nvme2n1", Controller: "nvme2", SizeBytes: 7681501126656, Purpose: "Ceph OSD", CephDaemon: "osd.0"},
		{NodeID: "150", Device: "nvme3n1", Controller: "nvme3", SizeBytes: 7681501126656, Purpose: "Ceph OSD", CephDaemon: "osd.1"},
	},
	"151": {
		{NodeID: "151", Device: "nvme0n1", Controller: "nvme0", SizeBytes: 960197124096, Purpose: "system"},
		{NodeID: "151", Device: "nvme1n1", Controller: "nvme1", SizeBytes: 960197124096, Purpose: "TiKV KV", Mountpoint: "/mnt/jfs-tikv"},
		{NodeID: "151", Device: "nvme2n1", Controller: "nvme2", SizeBytes: 7681501126656, Purpose: "Ceph OSD", CephDaemon: "osd.2"},
		{NodeID: "151", Device: "nvme3n1", Controller: "nvme3", SizeBytes: 7681501126656, Purpose: "Ceph OSD", CephDaemon: "osd.3"},
	},
	"152": {
		{NodeID: "152", Device: "nvme0n1", Controller: "nvme0", SizeBytes: 960197124096, Purpose: "system + Portal"},
		{NodeID: "152", Device: "nvme1n1", Controller: "nvme1", SizeBytes: 960197124096, Purpose: "TiKV KV", Mountpoint: "/mnt/jfs-tikv"},
		{NodeID: "152", Device: "nvme2n1", Controller: "nvme2", SizeBytes: 7681501126656, Purpose: "Ceph OSD", CephDaemon: "osd.5"},
		{NodeID: "152", Device: "nvme3n1", Controller: "nvme3", SizeBytes: 7681501126656, Purpose: "Ceph OSD", CephDaemon: "osd.4"},
	},
}

func nodeByID(id string) (nodeDefinition, bool) {
	for _, node := range clusterNodes {
		if node.ID == id {
			return node, true
		}
	}
	return nodeDefinition{}, false
}
