# Swift iOS Runtime PoC

iOS 17以上・arm64向けの実験アプリ。Discord Gatewayとオフライン計測を別タブに分けている。GitHub ActionsのmacOSランナーで未署名IPAを作る。

## インストール

Actionsの成功した実行から **SwiftIOSRuntimePoC-unsigned** を取得し、ZIP内のIPAをiPhoneの「ファイル」に移す。GitHubのアーティファクト取得にはサインインが必要。AltServerを起動し、iPhoneでDeveloper Modeを有効にして、AltStore Classicの **My Apps → ＋** からIPAを選び、署名・配備する。

## Discord Gateway

1. テスト用Botをテストサーバーに追加し、対象チャンネルで「チャンネルを見る」「メッセージを送信」の権限を付ける。特権インテントの設定は不要。
2. 「Discord」タブにBot TokenとチャンネルIDを入力して **Gateway接続**。WebSocket接続、Hello、READY、Heartbeat送信とACKの増加を個別に記録する。
3. **送信テスト** を一度押し、RESTの成功表示とチャンネル上のメッセージを確認する。RESTはGatewayの接続状態と独立して動く。
4. 切断・再接続試験では、ネットワークを短時間切って戻し、ログからResume/RESUMEDか再Identify/READYかを記録する。手動切断は自動再接続を停止する。

Tokenは実行中のメモリにのみ保持する。起動し直すと再入力が必要。エラー欄にレスポンス本文やTokenを出さない。Bot Tokenの入力画面やDiscordチャンネルが写ったスクリーンショットを共有する際は、共有前に内容を確認する。

## オフライン計測

開始時にGatewayとREST処理をキャンセルし、計測中はこのアプリから新規のDiscord操作を開始できない。通信の影響をさらに除く場合は機内モードとWi‑Fiオフで測る。

全モードは同じローカルSHA-256処理を10秒ごとに1バッチ実行して記録する。1分・5分・30分・8時間は連続実行した場合の目安。完了条件は実処理バッチ数（8時間は2,880件）。中断で未実行だったバッチは補完せず、次の実行から計測を続ける。終了通知が届かないままOSがプロセスを終了する場合もある。

| モード | バックグラウンドAPI | 終了の見方 |
| --- | --- | --- |
| A | 使用しない | tickの空白から実行が止まった可能性を推定 |
| B | 前面で計測を始める際に beginBackgroundTask | 猶予の期限を記録して解放。期限後も観測し、前面復帰時に実行猶予を再要求する |
| C | iOS 26以上の BGContinuedProcessingTask | バッチ数を進捗としてOSへ渡す。OSのLive Activity表示と取消、完了・失効を別々に確認 |

Cの要求をOSが受け付けられない場合は、待ち行列に入れず失敗を記録する。AltStoreの再署名でアプリのバンドルIDが変わり、許可タスクIDが追従しなかった場合はCを利用不可と表示する。A/BはこのタスクIDを使用しない。実機ではCの要求受付、進捗表示、完了、システムUIからの取消を確認する。

### テスト手順

各モードでまず1分・前面表示の基準値を取る。次に5分を選び、1件目のtick後にホームへ戻る試験と画面ロック試験を別々に行う。戻るまでの時間を外部の時計で測り、復帰後に次のtickを待ってから停止する。条件ごとに充電あり／なしを分ける。前面表示の長時間試験では画面が自動ロックされた時刻も確認する。短時間でCSV・失効・復帰時の挙動を確認してから、8時間設定で必要な条件を試す。

| 記録項目 | 記録内容 |
| --- | --- |
| 端末条件 | iPhone機種、iOSバージョン、低電力モード、充電有無、モード |
| 手順 | 前面／ホーム／ロック、移行・復帰時刻、選択時間、停止方法 |
| 観測 | 前面／背面で実際に記録されたtick数、最大連続稼働、推定空白、猶予失効・取消、CのLive Activity表示 |
| 記録ファイル | 停止後にCSVを共有シートから「ファイル」に保存し、試験条件と対応付ける |

CSVは計測ごとにアプリ内で永続保存され、再起動後も過去のファイルをエクスポートできる。UTC時刻、プロセスと計測それぞれの単調時計による経過時間、連番、状態、充電状態、イベント、進捗、ハッシュ、エラー情報を収録する。ロック条件は手順にも記録する。保護データ通知はOSから届いた場合のみ行を追加する。

予定の10秒より2秒超遅れたtickでは超過分を「推定空白」に加える。この値と最大連続稼働は観測されたtick間隔に基づくため、正確なOS停止時間や実稼働を保証しない。復帰時に過去のtickを生成しない。突然終了した場合はCSVの最終行より後の状態は不明。

## 仕様

- [Discord Gateway](https://docs.discord.com/developers/events/gateway)
- [Appleの継続処理API](https://developer.apple.com/documentation/backgroundtasks/bgcontinuedprocessingtask)
- [AltStore ClassicのWindows手順](https://faq.altstore.io/altstore-classic/how-to-install-altstore-windows)
