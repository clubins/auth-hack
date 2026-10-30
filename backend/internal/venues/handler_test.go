package venues

import (
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"reflect"
	"strings"
	"testing"
)

func TestHandlerRoutes(t *testing.T) {
	handler := NewHandler(NewMemStore(DefaultSeed()), nil)
	mux := http.NewServeMux()
	handler.Register(mux)
	srv := httptest.NewServer(mux)
	t.Cleanup(srv.Close)

	tests := []struct {
		name        string
		method      string
		target      string
		wantStatus  int
		wantBody    any    // decoded against the JSON response; nil skips body check
		wantContent string // expected Content-Type
	}{
		{
			name:        "list venues",
			method:      "GET",
			target:      "/venues",
			wantStatus:  http.StatusOK,
			wantBody:    normalize(t, DefaultSeed()),
			wantContent: "application/json",
		},
		{
			name:        "get one venue",
			method:      "GET",
			target:      "/venues/v-002",
			wantStatus:  http.StatusOK,
			wantBody:    normalize(t, DefaultSeed()[1]),
			wantContent: "application/json",
		},
		{
			name:        "unknown venue is 404 with json error",
			method:      "GET",
			target:      "/venues/nope",
			wantStatus:  http.StatusNotFound,
			wantBody:    map[string]any{"error": "venue not found"},
			wantContent: "application/json",
		},
		{
			name:       "method not allowed on collection",
			method:     "POST",
			target:     "/venues",
			wantStatus: http.StatusMethodNotAllowed,
		},
		{
			name:       "method not allowed on item",
			method:     "DELETE",
			target:     "/venues/v-001",
			wantStatus: http.StatusMethodNotAllowed,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			req, err := http.NewRequest(tt.method, srv.URL+tt.target, nil)
			if err != nil {
				t.Fatalf("build request: %v", err)
			}

			resp, err := srv.Client().Do(req)
			if err != nil {
				t.Fatalf("%s %s: %v", tt.method, tt.target, err)
			}
			t.Cleanup(func() { _ = resp.Body.Close() })

			if resp.StatusCode != tt.wantStatus {
				t.Fatalf("status = %d, want %d", resp.StatusCode, tt.wantStatus)
			}
			if got := resp.Header.Get("Content-Type"); tt.wantContent != "" && got != tt.wantContent {
				t.Fatalf("Content-Type = %q, want %q", got, tt.wantContent)
			}
			if tt.wantBody == nil {
				return
			}

			var gotBody any
			if err := json.NewDecoder(resp.Body).Decode(&gotBody); err != nil {
				t.Fatalf("decode body: %v", err)
			}
			if !reflect.DeepEqual(gotBody, tt.wantBody) {
				raw, _ := json.Marshal(gotBody)
				t.Fatalf("body = %s, want %v", raw, tt.wantBody)
			}
		})
	}
}

func TestHandlerListEmptyStoreRendersEmptyArray(t *testing.T) {
	handler := NewHandler(NewMemStore(nil), nil)
	mux := http.NewServeMux()
	handler.Register(mux)
	srv := httptest.NewServer(mux)
	t.Cleanup(srv.Close)

	resp, err := srv.Client().Get(srv.URL + "/venues")
	if err != nil {
		t.Fatalf("GET /venues: %v", err)
	}
	t.Cleanup(func() { _ = resp.Body.Close() })

	if resp.StatusCode != http.StatusOK {
		t.Fatalf("status = %d, want %d", resp.StatusCode, http.StatusOK)
	}

	body, err := io.ReadAll(resp.Body)
	if err != nil {
		t.Fatalf("read body: %v", err)
	}
	if got := strings.TrimSpace(string(body)); got != "[]" {
		t.Fatalf("body = %q, want %q (an empty list must serialize as [], not null)", got, "[]")
	}
}
