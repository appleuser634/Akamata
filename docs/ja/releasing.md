# Akamataのrelease手順

maintainer向けの簡潔なrelease手順です。

## Versioning

Akamataは`vMAJOR.MINOR.PATCH`形式のtagを使い、0.xでは次の方針でSemVerを運用します。

- `0.0.x`: bug fixと小さな互換変更
- `0.x.0`: 大きなfeatureやAPI変更
- `1.0.0`: stable public APIのcommit

versionのsource of truthは`build.zig.zon`です。CLI version、scaffold metadata、CHANGELOG、release noteを同期してください。

## Checklist

1. `main`と既存tagを確認し、working treeに意図しない変更がないことを確認します。
2. `build.zig.zon`、`tools/akamata/src/main.zig`、scaffold template、README、CHANGELOGを更新します。
3. release gateを実行します。

   ```bash
   zig build test
   zig build cli
   zig build scaffold-test
   zig build -Dexample=chat
   zig build -Dexample=chat -Dbackend=workers -Doptimize=ReleaseSmall
   ```

4. `akamata --version`、`akamata help`、`akamata deploy --help`、`akamata migrate --help`を確認します。
5. release準備変更をcommitします。
6. annotated tagを作成します。

   ```bash
   git tag -a vX.Y.Z -m "Akamata vX.Y.Z"
   git push origin main
   git push origin vX.Y.Z
   ```

7. `Akamata vX.Y.Z`というtitleで、draftでもpre-releaseでもないGitHub Releaseを作成します。release noteにはCHANGELOGの該当sectionを使います。
8. tag archiveをZigでfetchし、content hashを検証します。

   ```bash
   zig fetch https://github.com/appleuser634/Akamata/archive/refs/tags/vX.Y.Z.tar.gz
   ```

9. tagが存在してから、scaffold dependencyをstable tagと正確なhashへ更新します。archive自身のhashを同じarchiveへ入れる自己参照は循環するため、release準備commitとrelease後のpin更新を分けます。初回v0.0.1はimmutableなrelease準備revisionを参照し、次回以降は直前のstable releaseを参照します。
10. checkoutと無関係なdirectoryで`akamata init release-smoke --target=both`を実行し、`zig build`、Workers build、`akamata migrate up`を確認します。

## Tag convention

tagは必ず`vMAJOR.MINOR.PATCH`とし、annotated tagを使用します。公開済みtagをforce updateしません。問題があれば新しいpatch versionを公開します。

## Release artifact

GitHub Releaseを公開releaseの記録とします。この手順はpackage registry、Homebrew、container registryの公開を意味しません。
