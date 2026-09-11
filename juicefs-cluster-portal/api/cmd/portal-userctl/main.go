package main

import (
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"flag"
	"fmt"
	"os"
	"path/filepath"
	"time"

	"juicefs-cluster-portal/api/internal/portal"
)

func main() {
	if len(os.Args) < 2 || os.Args[1] != "init" {
		fmt.Fprintln(os.Stderr, "usage: portal-userctl init --users-file PATH --secret-file PATH --credentials-file PATH")
		os.Exit(2)
	}
	flags := flag.NewFlagSet("init", flag.ExitOnError)
	usersFile := flags.String("users-file", "", "users JSON output")
	secretFile := flags.String("secret-file", "", "session secret output")
	credentialsFile := flags.String("credentials-file", "", "one-time bootstrap credentials output")
	_ = flags.Parse(os.Args[2:])
	for _, path := range []string{*usersFile, *secretFile, *credentialsFile} {
		if !filepath.IsAbs(path) {
			fmt.Fprintln(os.Stderr, "all output paths must be absolute")
			os.Exit(2)
		}
		if _, err := os.Lstat(path); err == nil || !os.IsNotExist(err) {
			fmt.Fprintf(os.Stderr, "refuse existing output: %s\n", path)
			os.Exit(1)
		}
	}

	adminPassword := randomCredential(24)
	userPassword := randomCredential(24)
	adminHash, err := portal.HashPassword(adminPassword)
	check(err)
	userHash, err := portal.HashPassword(userPassword)
	check(err)
	document := struct {
		Version int                `json:"version"`
		Users   []portal.LocalUser `json:"users"`
	}{Version: 1, Users: []portal.LocalUser{
		{Username: "admin", Role: "ADMIN", PasswordHash: adminHash},
		{Username: "user", Role: "USER", PasswordHash: userHash},
	}}
	usersJSON, err := json.MarshalIndent(document, "", "  ")
	check(err)
	usersJSON = append(usersJSON, '\n')
	secret := randomBytes(32)
	credentials := fmt.Sprintf("generated_at=%s\nadmin=%s\nuser=%s\n", time.Now().UTC().Format(time.RFC3339), adminPassword, userPassword)

	check(writeExclusive(*usersFile, usersJSON))
	if err := writeExclusive(*secretFile, []byte(hex.EncodeToString(secret)+"\n")); err != nil {
		_ = os.Remove(*usersFile)
		check(err)
	}
	if err := writeExclusive(*credentialsFile, []byte(credentials)); err != nil {
		_ = os.Remove(*usersFile)
		_ = os.Remove(*secretFile)
		check(err)
	}
	fmt.Printf("PORTAL_USER_INIT_PASS users=%s credentials=%s\n", *usersFile, *credentialsFile)
}

func randomCredential(bytes int) string {
	return hex.EncodeToString(randomBytes(bytes))
}

func randomBytes(length int) []byte {
	value := make([]byte, length)
	if _, err := rand.Read(value); err != nil {
		check(err)
	}
	return value
}

func writeExclusive(path string, data []byte) error {
	file, err := os.OpenFile(path, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0o600)
	if err != nil {
		return err
	}
	if _, err := file.Write(data); err != nil {
		_ = file.Close()
		return err
	}
	return file.Close()
}

func check(err error) {
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}
