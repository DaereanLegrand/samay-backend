package ops

import "errors"

var (
	// ErrNotFound indicates the requested resource does not exist.
	ErrNotFound = errors.New("not found")
	// ErrInvalid indicates the request or input is malformed.
	ErrInvalid = errors.New("invalid")
	// ErrUnauthorized indicates the caller lacks permission.
	ErrUnauthorized = errors.New("unauthorized")
)
