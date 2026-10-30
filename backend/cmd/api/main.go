// Command api serves the Clubins auth-hack reference API. This seed exposes
// only a health endpoint; the OIDC guard, venues domain, and renter grants
// land in later component tasks.
package main

import (
	"encoding/json"
	"log"
	"net/http"
	"os"
)

func main() {
	addr := ":8080"
	if port := os.Getenv("PORT"); port != "" {
		addr = ":" + port
	}

	log.Printf("listening on %s", addr)
	log.Fatal(http.ListenAndServe(addr, newServer()))
}

// newServer wires the API routes. Method-pattern routing requires Go 1.22+.
func newServer() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /healthz", handleHealthz)
	return mux
}

func handleHealthz(w http.ResponseWriter, _ *http.Request) {
	w.Header().Set("Content-Type", "application/json")
	if err := json.NewEncoder(w).Encode(map[string]string{"status": "ok"}); err != nil {
		log.Printf("write healthz response: %v", err)
	}
}
