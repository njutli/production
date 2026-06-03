package main

import (
	"context"
	"fmt"
	"os"
	"time"

	"github.com/tikv/client-go/v2/rawkv"
)

func main() {
	pdAddrs := []string{"192.168.11.12:2379"}

	client, err := rawkv.NewClient(context.Background(), pdAddrs)
	if err != nil {
		fmt.Fprintf(os.Stderr, "ERROR: cannot connect to TiKV: %v\n", err)
		os.Exit(1)
	}
	defer client.Close()

	fmt.Println("========================================")
	fmt.Println("TiKV RawKV Smoke Test")
	fmt.Println("========================================")
	fmt.Printf("PD: %v\n\n", pdAddrs)

	passed, failed := 0, 0
	prefix := fmt.Sprintf("smoke_test_%d_", time.Now().UnixNano())

	// -------------------------------------------------------
	// Test 1: Put + Get
	// -------------------------------------------------------
	fmt.Println("[Test 1] Basic Put/Get")
	key1 := []byte(prefix + "single_key")
	value1 := []byte("smoke_test_value_hello_world")

	err = client.Put(context.Background(), key1, value1)
	if err != nil {
		fmt.Printf("  FAIL: Put error: %v\n", err)
		failed++
	} else {
		got, err := client.Get(context.Background(), key1)
		if err != nil {
			fmt.Printf("  FAIL: Get error: %v\n", err)
			failed++
		} else if string(got) != string(value1) {
			fmt.Printf("  FAIL: value mismatch (got %q, want %q)\n", got, value1)
			failed++
		} else {
			fmt.Println("  PASS")
			passed++
		}
	}

	// -------------------------------------------------------
	// Test 2: Batch Put + Batch Get
	// -------------------------------------------------------
	fmt.Println("[Test 2] Batch Put/Get (10 keys)")
	count := 10
	keys := make([][]byte, count)
	vals := make([][]byte, count)
	for i := 0; i < count; i++ {
		keys[i] = []byte(fmt.Sprintf("%sbatch_%04d", prefix, i))
		vals[i] = []byte(fmt.Sprintf("batch_value_%d", i))
	}

	err = client.BatchPut(context.Background(), keys, vals)
	if err != nil {
		fmt.Printf("  FAIL: BatchPut error: %v\n", err)
		failed++
	} else {
		match := 0
		for i := 0; i < count; i++ {
			v, err := client.Get(context.Background(), keys[i])
			if err == nil && string(v) == string(vals[i]) {
				match++
			}
		}
		if match != count {
			fmt.Printf("  FAIL: matched %d/%d\n", match, count)
			failed++
		} else {
			fmt.Println("  PASS")
			passed++
		}
	}

	// -------------------------------------------------------
	// Test 3: Scan
	// -------------------------------------------------------
	fmt.Println("[Test 3] Scan range (10 keys)")
	scanKeys, _, err := client.Scan(
		context.Background(),
		[]byte(prefix+"batch_0000"),
		[]byte(prefix+"batch_0010"),
		20,
	)
	if err != nil {
		fmt.Printf("  FAIL: Scan error: %v\n", err)
		failed++
	} else if len(scanKeys) != count {
		fmt.Printf("  FAIL: scan saw %d keys, expected %d\n", len(scanKeys), count)
		failed++
	} else {
		fmt.Println("  PASS")
		passed++
	}

	// -------------------------------------------------------
	// Test 4: Delete + verify
	// -------------------------------------------------------
	fmt.Println("[Test 4] Delete + verify")

	// Delete single key
	err = client.Delete(context.Background(), key1)
	if err != nil {
		fmt.Printf("  FAIL: Delete error: %v\n", err)
		failed++
	} else {
		got, _ := client.Get(context.Background(), key1)
		if got != nil {
			fmt.Printf("  FAIL: key still exists after delete\n")
			failed++
		} else {
			fmt.Println("  PASS (single key deleted)")
			passed++
		}
	}

	// Batch delete the remaining keys
	err = client.BatchDelete(context.Background(), keys)
	if err != nil {
		fmt.Printf("  FAIL: BatchDelete error: %v\n", err)
		failed++
	} else {
		// Verify all batch keys are gone
		remaining := 0
		for _, k := range keys {
			v, _ := client.Get(context.Background(), k)
			if v != nil {
				remaining++
			}
		}
		if remaining > 0 {
			fmt.Printf("  FAIL: %d keys still exist after batch delete\n", remaining)
			failed++
		} else {
			fmt.Println("  PASS (batch keys deleted)")
			passed++
		}
	}

	// -------------------------------------------------------
	// Summary
	// -------------------------------------------------------
	fmt.Println("")
	fmt.Println("========================================")
	fmt.Printf("Result: %d passed, %d failed\n", passed, failed)
	fmt.Println("========================================")

	if failed > 0 {
		os.Exit(1)
	}
}
