package clashapi

import (
	"context"
	"encoding/json"
	"net/http"
)

type bywayPrivateEndpoint interface {
	BywayPrivateStatus(context.Context) ([]byte, error)
	BywayPrivateAction(context.Context, string, string) ([]byte, error)
}

func (s *Server) bywayPrivate() bywayPrivateEndpoint {
	endpoint, _ := s.endpoint.Get("byway-private")
	provider, _ := endpoint.(bywayPrivateEndpoint)
	return provider
}

func (s *Server) bywayPrivateStatus(w http.ResponseWriter, r *http.Request) {
	provider := s.bywayPrivate()
	if provider == nil {
		http.Error(w, "private network is not running", http.StatusConflict)
		return
	}
	data, err := provider.BywayPrivateStatus(r.Context())
	writeBywayPrivate(w, data, err)
}

func (s *Server) bywayPrivateAction(w http.ResponseWriter, r *http.Request) {
	provider := s.bywayPrivate()
	if provider == nil {
		http.Error(w, "private network is not running", http.StatusConflict)
		return
	}
	var input struct {
		Action string `json:"action"`
		Value  string `json:"value"`
	}
	body := http.MaxBytesReader(w, r.Body, 8192)
	if err := json.NewDecoder(body).Decode(&input); err != nil {
		http.Error(w, "invalid private network request", http.StatusBadRequest)
		return
	}
	data, err := provider.BywayPrivateAction(r.Context(), input.Action, input.Value)
	writeBywayPrivate(w, data, err)
}

func writeBywayPrivate(w http.ResponseWriter, data []byte, err error) {
	w.Header().Set("Cache-Control", "no-store")
	if err != nil {
		http.Error(w, err.Error(), http.StatusConflict)
		return
	}
	w.Header().Set("Content-Type", "application/json")
	_, _ = w.Write(data)
}
