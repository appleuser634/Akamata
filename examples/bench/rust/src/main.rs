// Equivalent Rust Axum (Tokio) bench server.
// Three endpoints matching Akamata's:
//   GET  /hello       — static text
//   POST /echo        — JSON parse + JSON serialise
//   GET  /db/:id      — SQLite (in-memory) lookup

use axum::{
    extract::{Path, State},
    routing::{get, post},
    Json, Router,
};
use rusqlite::Connection;
use serde::{Deserialize, Serialize};
use std::sync::Mutex;
use std::sync::Arc;

#[derive(Clone)]
struct AppState {
    db: Arc<Mutex<Connection>>,
}

#[derive(Deserialize)]
struct EchoIn {
    name: String,
    #[serde(default)]
    n: u32,
}

#[derive(Serialize)]
struct EchoOut<'a> {
    name: &'a str,
    n: u32,
    echoed: bool,
}

#[derive(Serialize)]
struct Item {
    id: i64,
    name: String,
    weight: f64,
}

async fn hello() -> &'static str {
    "Hello, Akamata!"
}

async fn echo(Json(body): Json<EchoIn>) -> Json<serde_json::Value> {
    Json(serde_json::json!({
        "name": body.name,
        "n": body.n,
        "echoed": true,
    }))
}

async fn lookup(Path(id): Path<i64>, State(s): State<AppState>) -> Json<serde_json::Value> {
    let db = s.db.lock().unwrap();
    let mut stmt = db.prepare("SELECT id, name, weight FROM items WHERE id = ?").unwrap();
    let mut rows = stmt.query([id]).unwrap();
    if let Some(row) = rows.next().unwrap() {
        let item = Item {
            id: row.get(0).unwrap(),
            name: row.get(1).unwrap(),
            weight: row.get(2).unwrap(),
        };
        Json(serde_json::json!({ "id": item.id, "name": item.name, "weight": item.weight }))
    } else {
        Json(serde_json::json!({ "error_kind": "not_found" }))
    }
}

#[tokio::main]
async fn main() {
    let db = Connection::open_in_memory().unwrap();
    db.execute_batch(
        "CREATE TABLE items (id INTEGER PRIMARY KEY, name TEXT NOT NULL, weight REAL);
         INSERT INTO items(id, name, weight) VALUES (1,'alpha',1.5);
         INSERT INTO items(id, name, weight) VALUES (2,'beta',2.5);
         INSERT INTO items(id, name, weight) VALUES (3,'gamma',3.5);",
    )
    .unwrap();
    let state = AppState { db: Arc::new(Mutex::new(db)) };

    let app = Router::new()
        .route("/hello", get(hello))
        .route("/echo", post(echo))
        .route("/db/:id", get(lookup))
        .with_state(state);

    let listener = tokio::net::TcpListener::bind("0.0.0.0:8083").await.unwrap();
    println!("listening on :8083");
    axum::serve(listener, app).await.unwrap();
}
