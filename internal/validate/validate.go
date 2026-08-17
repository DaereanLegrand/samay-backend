// Package validate provides shared input-validation helpers used by both
// the CLI (cmd/samay-admin) and the HTTP API server (cmd/samay-api-server).
package validate

import (
	"fmt"
	"strconv"
	"strings"
	"time"
)

// oneOf returns nil if value is one of the allowed strings, otherwise an error.
func oneOf(value string, allowed ...string) error {
	for _, a := range allowed {
		if value == a {
			return nil
		}
	}
	return fmt.Errorf("invalid value %q: must be one of %s", value, strings.Join(allowed, ", "))
}

// OneOf returns nil if value is one of the allowed strings, otherwise an error.
func OneOf(value string, allowed ...string) error {
	return oneOf(value, allowed...)
}

// parseDate parses a date string in "YYYY-MM-DD" format.
func parseDate(s string) (time.Time, error) {
	t, err := time.Parse("2006-01-02", s)
	if err != nil {
		return time.Time{}, fmt.Errorf("invalid date %q: must be YYYY-MM-DD", s)
	}
	return t, nil
}

// ParseDate parses a date string in "YYYY-MM-DD" format.
func ParseDate(s string) (time.Time, error) {
	return parseDate(s)
}

// parsePositiveInt parses a string as a positive integer.
func parsePositiveInt(s string) (int, error) {
	n, err := strconv.Atoi(s)
	if err != nil || n <= 0 {
		return 0, fmt.Errorf("invalid amount %q: must be a positive integer", s)
	}
	return n, nil
}

// ParsePositiveInt parses a string as a positive integer.
func ParsePositiveInt(s string) (int, error) {
	return parsePositiveInt(s)
}

// parseUUID validates that s is a 36-character UUID with correct dash placement.
func parseUUID(s string) error {
	if len(s) != 36 {
		return fmt.Errorf("invalid id %q: must be a UUID", s)
	}
	for i, r := range s {
		if i == 8 || i == 13 || i == 18 || i == 23 {
			if r != '-' {
				return fmt.Errorf("invalid id %q: must be a UUID", s)
			}
			continue
		}
		if !((r >= '0' && r <= '9') || (r >= 'a' && r <= 'f') || (r >= 'A' && r <= 'F')) {
			return fmt.Errorf("invalid id %q: must be a UUID", s)
		}
	}
	return nil
}

// ParseUUID validates that s is a 36-character UUID with correct dash placement.
func ParseUUID(s string) error {
	return parseUUID(s)
}
