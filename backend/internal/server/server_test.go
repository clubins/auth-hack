package server

import (
	"bytes"
	"encoding/json"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"reflect"
	"strings"
	"testing"

	"github.com/clubins/auth-hack/backend/internal/venues"
)

func TestRoutes(t *testing.T) {
	srv := httptest.NewServer(New(Options{Store: venues.NewMemStore(venues.DefaultSeed())}))
	t.Cleanup(srv.Close)

	tests := []struct {
		name        string
		method      string
		target      string
		wantStatus  int
		wantBody    any // decoded against the JSON response; nil skips body check
		wantContent string
	}{
		{
			name:        "healthz stays json ok",
			method:      "GET",
			target:      "/healthz",
			wantStatus:  http.StatusOK,
			wantBody:    map[string]any{"status": "ok"},
			wantContent: "application/json",
		},
		{
			name:        "venues list over the wired store",
			method:      "GET",
			target:      "/venues",
			wantStatus:  http.StatusOK,
			wantBody:    venuesJSON(t),
			wantContent: "application/json",
		},
		{
			name:        "one venue through the wired store",
			method:      "GET",
			target:      "/venues/v-001",
			wantStatus:  http.StatusOK,
			wantContent: "application/json",
		},
		{
			name:        "grants list is wired and empty",
			method:      "GET",
			target:      "/venues/v-001/grants",
			wantStatus:  http.StatusOK,
			wantBody:    []any{},
			wantContent: "application/json",
		},
		{
			name:        "unknown venue is a json 404",
			method:      "GET",
			target:      "/venues/nope",
			wantStatus:  http.StatusNotFound,
			wantBody:    map[string]any{"error": "venue not found"},
			wantContent: "application/json",
		},
		{
			name:       "unmatched route is still a 404",
			method:     "GET",
			target:     "/definitely-not-a-route",
			wantStatus: http.StatusNotFound,
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
				t.Fatalf("body = %v, want %v", gotBody, tt.wantBody)
			}
		})
	}
}

// venuesJSON is the expected /venues body for the DefaultSeed, round-tripped
// through JSON the way a client sees it.
func venuesJSON(t *testing.T) any {
	t.Helper()
	b, err := json.Marshal(venues.DefaultSeed())
	if err != nil {
		t.Fatalf("marshal seed: %v", err)
	}
	var out any
	if err := json.Unmarshal(b, &out); err != nil {
		t.Fatalf("unmarshal seed: %v", err)
	}
	return out
}

func TestNewWithoutOptionsServesEmptyVenues(t *testing.T) {
	srv := httptest.NewServer(New(Options{}))
	t.Cleanup(srv.Close)

	resp, err := srv.Client().Get(srv.URL + "/venues")
	if err != nil {
		t.Fatalf("GET /venues: %v", err)
	}
	t.Cleanup(func() { _ = resp.Body.Close() })

	if resp.StatusCode != http.StatusOK {
		t.Fatalf("status = %d, want %d", resp.StatusCode, http.StatusOK)
	}
	var got []any
	if err := json.NewDecoder(resp.Body).Decode(&got); err != nil {
		t.Fatalf("decode body: %v", err)
	}
	if len(got) != 0 {
		t.Fatalf("venues = %v, want empty", got)
	}
}

func TestRequestLogging(t *testing.T) {
	var buf bytes.Buffer
	logger := slog.New(slog.NewJSONHandler(&buf, &slog.HandlerOptions{Level: slog.LevelDebug}))

	srv := httptest.NewServer(New(Options{Logger: logger, Store: venues.NewMemStore(venues.DefaultSeed())}))
	t.Cleanup(srv.Close)

	req, err := http.NewRequest("GET", srv.URL+"/healthz", nil)
	if err != nil {
		t.Fatalf("build request: %v", err)
	}
	// A bearer token a real client would send — it must never reach the log.
	req.Header.Set("Authorization", "Bearer super-secret-token")

	resp, err := srv.Client().Do(req)
	if err != nil {
		t.Fatalf("GET /healthz: %v", err)
	}
	t.Cleanup(func() { _ = resp.Body.Close() })
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("status = %d, want %d", resp.StatusCode, http.StatusOK)
	}

	line := strings.TrimSpace(buf.String())
	if line == "" {
		t.Fatal("expected a request log entry")
	}

	var entry map[string]any
	if err := json.Unmarshal([]byte(line), &entry); err != nil {
		t.Fatalf("request log is not structured JSON: %q", line)
	}
	for key, want := range map[string]any{"msg": "request", "method": "GET", "path": "/healthz", "status": float64(http.StatusOK)} {
		if entry[key] != want {
			t.Fatalf("request log %s = %v, want %v", key, entry[key], want)
		}
	}
	if strings.Contains(buf.String(), "super-secret-token") {
		t.Fatal("request log leaked the bearer token")
	}
}
