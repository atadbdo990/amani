// AMANI-MORA — Xray config generator
//
// Reads /config.json.tpl, substitutes placeholders from environment
// variables, writes the result to /tmp/config.json, then execs xray
// with that config. This binary does not read, write, or transmit
// any data outside of this container/host.
package main

import (
	"io/ioutil"
	"log"
	"os"
	"os/exec"
	"os/signal"
	"strings"
	"syscall"
)

func getenv(key, def string) string {
	v := os.Getenv(key)
	if v == "" {
		return def
	}
	return v
}

func main() {
	// Read template
	tplPath := "/config.json.tpl"
	data, err := ioutil.ReadFile(tplPath)
	if err != nil {
		log.Fatalf("failed to read template %s: %v", tplPath, err)
	}
	s := string(data)

	// Gather envs with defaults
	proto := getenv("PROTO", "vless")
	user := getenv("USER_ID", getenv("UUID", "changeme"))
	wspath := getenv("WS_PATH", "/ws")
	network := getenv("NETWORK", "ws")
	port := getenv("PORT", "8080")
	speedLimit := getenv("SPEED_LIMIT", "0") // 0 = unlimited
	host := getenv("HOST", "localhost")      // WebSocket host header

	// replace placeholders
	repl := map[string]string{
		"__PROTO__":       proto,
		"__USER_ID__":     user,
		"__WS_PATH__":     wspath,
		"__NETWORK__":     network,
		"__PORT__":        port,
		"__SPEED_LIMIT__": speedLimit,
		"__HOST__":        host,
	}
	for k, v := range repl {
		s = strings.ReplaceAll(s, k, v)
	}

	// write output to a writable location
	outPath := "/tmp/config.json"
	if err := ioutil.WriteFile(outPath, []byte(s), 0644); err != nil {
		log.Fatalf("failed to write config: %v", err)
	}

	// Start xray as a child process
	path, err := exec.LookPath("xray")
	if err != nil {
		log.Fatalf("xray binary not found in PATH: %v", err)
	}
	args := []string{"run", "-config", outPath}
	cmd := exec.Command(path, args...)
	cmd.Env = os.Environ()
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	cmd.Stdin = os.Stdin

	if err := cmd.Start(); err != nil {
		log.Fatalf("failed to start xray: %v", err)
	}

	// Setup signal handler to terminate xray on exit
	sigCh := make(chan os.Signal, 1)
	signal.Notify(sigCh, syscall.SIGINT, syscall.SIGTERM)
	go func() {
		s := <-sigCh
		log.Printf("received signal %v, shutting down xray", s)
		if cmd.Process != nil {
			_ = cmd.Process.Kill()
		}
		os.Exit(0)
	}()

	// Wait for xray to exit (blocking)
	if err := cmd.Wait(); err != nil {
		log.Printf("xray exited with error: %v", err)
	}
}
