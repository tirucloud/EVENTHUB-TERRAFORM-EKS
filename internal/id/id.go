// Package id generates short, sortable, URL-safe identifiers.
//
// This exists so the services do not pull in a UUID dependency: fewer modules
// means a smaller image and a shorter Trivy report.
package id

import (
	"crypto/rand"
	"encoding/base32"
	"encoding/binary"
	"time"
)

var encoding = base32.NewEncoding("0123456789abcdefghjkmnpqrstvwxyz").WithPadding(base32.NoPadding)

// New returns a 26-character identifier prefixed with the given tag, e.g.
// "evt_0004m1c0k8r7g3p9zq2xv1n5tb". The first 6 bytes are a big-endian
// millisecond timestamp, so identifiers sort chronologically as plain strings.
func New(prefix string) string {
	var buf [16]byte

	ms := uint64(time.Now().UTC().UnixMilli())
	buf[0] = byte(ms >> 40)
	buf[1] = byte(ms >> 32)
	buf[2] = byte(ms >> 24)
	buf[3] = byte(ms >> 16)
	buf[4] = byte(ms >> 8)
	buf[5] = byte(ms)

	if _, err := rand.Read(buf[6:]); err != nil {
		// crypto/rand never fails on Linux; fall back to the clock so that a
		// pathological environment degrades instead of panicking.
		binary.BigEndian.PutUint64(buf[6:14], uint64(time.Now().UnixNano()))
	}

	if prefix == "" {
		return encoding.EncodeToString(buf[:])
	}
	return prefix + "_" + encoding.EncodeToString(buf[:])
}
