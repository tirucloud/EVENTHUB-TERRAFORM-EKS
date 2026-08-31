package httpx

import (
	"encoding/json"
	"log/slog"
	"net/http"
)

// ErrorBody is the single error shape every EventHub service returns, so the
// frontend only ever has to parse one thing.
type ErrorBody struct {
	Error   string `json:"error"`
	Message string `json:"message"`
}

// JSON writes v as an indented JSON response with the given status code.
func JSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.WriteHeader(status)

	if v == nil {
		return
	}
	enc := json.NewEncoder(w)
	enc.SetIndent("", "  ")
	if err := enc.Encode(v); err != nil {
		// The status line is already on the wire, so all we can do is record it.
		slog.Error("failed to encode response body", slog.Any("error", err))
	}
}

// Error writes a structured error response. code is a stable machine-readable
// slug ("event_not_found"); message is the human-facing detail.
func Error(w http.ResponseWriter, status int, code, message string) {
	JSON(w, status, ErrorBody{Error: code, Message: message})
}

// DecodeJSON reads the request body into dst, rejecting unknown fields and
// bodies larger than 1 MiB. It reports whether decoding succeeded, having
// already written the error response when it did not.
func DecodeJSON(w http.ResponseWriter, r *http.Request, dst any) bool {
	r.Body = http.MaxBytesReader(w, r.Body, 1<<20)

	dec := json.NewDecoder(r.Body)
	dec.DisallowUnknownFields()

	if err := dec.Decode(dst); err != nil {
		Error(w, http.StatusBadRequest, "invalid_json", err.Error())
		return false
	}
	return true
}
