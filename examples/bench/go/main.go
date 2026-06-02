// Equivalent Go net/http bench server for comparison.
package main

import (
	"database/sql"
	"encoding/json"
	"log"
	"net/http"
	"strconv"
	"strings"

	_ "modernc.org/sqlite"
)

var db *sql.DB

func main() {
	var err error
	db, err = sql.Open("sqlite", ":memory:")
	if err != nil {
		log.Fatal(err)
	}
	_, err = db.Exec(`
		CREATE TABLE items (id INTEGER PRIMARY KEY, name TEXT NOT NULL, weight REAL);
		INSERT INTO items(id, name, weight) VALUES (1,'alpha',1.5);
		INSERT INTO items(id, name, weight) VALUES (2,'beta',2.5);
		INSERT INTO items(id, name, weight) VALUES (3,'gamma',3.5);
	`)
	if err != nil {
		log.Fatal(err)
	}

	mux := http.NewServeMux()
	mux.HandleFunc("/hello", hello)
	mux.HandleFunc("/echo", echoH)
	mux.HandleFunc("/db/", lookup)

	srv := &http.Server{Addr: ":8081", Handler: mux}
	log.Println("listening on :8081")
	log.Fatal(srv.ListenAndServe())
}

func hello(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "text/plain; charset=utf-8")
	w.Write([]byte("Hello, Yuntaku!"))
}

type echoBody struct {
	Name string `json:"name"`
	N    int    `json:"n"`
}

func echoH(w http.ResponseWriter, r *http.Request) {
	var b echoBody
	if err := json.NewDecoder(r.Body).Decode(&b); err != nil {
		http.Error(w, `{"error_kind":"bad_request"}`, 400)
		return
	}
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(map[string]any{"name": b.Name, "n": b.N, "echoed": true})
}

func lookup(w http.ResponseWriter, r *http.Request) {
	idStr := strings.TrimPrefix(r.URL.Path, "/db/")
	id, err := strconv.ParseInt(idStr, 10, 64)
	if err != nil {
		http.Error(w, `{"error_kind":"bad_id"}`, 400)
		return
	}
	var name string
	var weight float64
	err = db.QueryRow("SELECT name, weight FROM items WHERE id = ?", id).Scan(&name, &weight)
	if err == sql.ErrNoRows {
		http.Error(w, `{"error_kind":"not_found"}`, 404)
		return
	}
	if err != nil {
		http.Error(w, "internal", 500)
		return
	}
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(map[string]any{"id": id, "name": name, "weight": weight})
}
