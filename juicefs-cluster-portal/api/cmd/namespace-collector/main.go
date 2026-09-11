package main

import (
	"context"
	"flag"
	"log"
	"os"
	"time"

	"juicefs-cluster-portal/api/internal/namespacecollector"
)

func main() {
	configPath := flag.String("config", "", "absolute path to the namespace roots JSON config")
	dbPath := flag.String("db", "", "absolute path to the namespace SQLite database")
	juicefsPath := flag.String("juicefs", "", "absolute path to the JuiceFS executable")
	timeout := flag.Duration("timeout", 15*time.Second, "per-root JuiceFS summary timeout")
	allowWritable := flag.Bool("allow-writable-roots", false, "allow a dedicated writable control mount required by JuiceFS summary")
	flag.Parse()
	if flag.NArg() != 0 || *configPath == "" || *dbPath == "" || *juicefsPath == "" {
		flag.Usage()
		os.Exit(2)
	}
	config, err := namespacecollector.LoadConfig(*configPath)
	if err != nil {
		log.Fatal(err)
	}
	if err := namespacecollector.Run(context.Background(), namespacecollector.Options{
		DBPath:             *dbPath,
		JuiceFSBinary:      *juicefsPath,
		Config:             config,
		CollectionTimeout:  *timeout,
		AllowWritableRoots: *allowWritable,
	}); err != nil {
		log.Fatal(err)
	}
	log.Printf("namespace snapshot updated for %d root(s)", len(config.Roots))
}
