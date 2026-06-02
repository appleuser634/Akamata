# SQLite amalgamation

このディレクトリには SQLite の amalgamation (`sqlite3.c` / `sqlite3.h`) を配置する。Akamata が `@cImport` 経由で取り込むため、Zig パッケージ依存を増やさずに SQLite を利用できる。

## 取得方法

```bash
cd third_party/sqlite
./fetch.sh
```

または手動で:

```bash
curl -L -o /tmp/sqlite.zip https://www.sqlite.org/2025/sqlite-amalgamation-3460100.zip
unzip -j /tmp/sqlite.zip 'sqlite-amalgamation-*/sqlite3.c' 'sqlite-amalgamation-*/sqlite3.h' -d third_party/sqlite/
```

## ライセンス

SQLite は Public Domain。
