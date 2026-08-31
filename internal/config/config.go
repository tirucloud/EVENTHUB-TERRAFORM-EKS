// Package config reads service configuration from environment variables.
//
// Every EventHub service is configured exclusively through the environment so
// that the same image can run under docker-compose locally and as a Kubernetes
// Deployment in EKS with nothing but a different ConfigMap.
package config

import (
	"os"
	"strconv"
	"strings"
	"time"
)

// String returns the value of key, or def when the variable is unset or empty.
func String(key, def string) string {
	if v := strings.TrimSpace(os.Getenv(key)); v != "" {
		return v
	}
	return def
}

// Int returns the value of key parsed as an int, or def when unset or invalid.
func Int(key string, def int) int {
	v := strings.TrimSpace(os.Getenv(key))
	if v == "" {
		return def
	}
	n, err := strconv.Atoi(v)
	if err != nil {
		return def
	}
	return n
}

// Bool returns the value of key parsed as a bool, or def when unset or invalid.
// Accepts the usual 1/t/T/true/TRUE spellings understood by strconv.
func Bool(key string, def bool) bool {
	v := strings.TrimSpace(os.Getenv(key))
	if v == "" {
		return def
	}
	b, err := strconv.ParseBool(v)
	if err != nil {
		return def
	}
	return b
}

// Duration returns the value of key parsed as a Go duration ("5s", "1m30s"),
// or def when unset or invalid.
func Duration(key string, def time.Duration) time.Duration {
	v := strings.TrimSpace(os.Getenv(key))
	if v == "" {
		return def
	}
	d, err := time.ParseDuration(v)
	if err != nil {
		return def
	}
	return d
}
