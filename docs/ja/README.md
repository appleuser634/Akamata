# Akamataドキュメント

このページはAkamata 0.3／Zig 0.16.x向けドキュメントの入口です。フレームワークを初めて試す場合はクイックスタートから始め、HandbookまたはTutorialで理解を深めてください。

[English](../en/README.md) · [プロジェクトREADME](../../README.ja.md)

## はじめに

- [クイックスタート](quickstart.md) — CLIをインストールし、現在のscaffoldを生成して起動します
- [Tutorial](tutorial.md) — アプリケーションを段階的に構築します
- [Handbook](handbook.md) — model、repository、migration、deployを短時間で確認します
- [Tasks example](example-tasks.md) — example applicationを題材に学びます

## Guide

- [Cloudflare Workers／Containers](cloudflare.md)
- [SQLite／D1／Turso](db-backends.md)
- [WebSocket](websocket.md)
- [Observability](observability.md)
- [Security](security.md)
- [Mobus deployment](mobus-deployment.md)と[portability notes](mobus-portability.md)

## API reference

- [Handler API](handler-api.md) — `App`、`Context`、request／response helper、middleware、database、model／repository、HTTP client、認証、WebSocket、SSE

## 本番運用とperformance

- [Benchmarks](benchmarks.md)
- [Long-run benchmarks](benchmarks-long-run.md)
- [Performance follow-ups](perf-followups.md)
- [Reactor design](perf-reactor-design.md)

benchmark値は、記載された環境、command、Akamata revisionでの測定結果です。別のmachineやworkloadで同じ性能を保証するものではありません。

## Architectureと設計資料

- [Architecture](architecture.md)
- [v0.2 design record](v0.2-design.md)
- [過去のAPI redesign記録](hono-style-redesign.md)

設計資料は特定時点の検討内容を記録したもので、現在は置き換えられた例を含む場合があります。対応中のinterfaceは[Handler API](handler-api.md)と現在のsource codeを確認してください。
