# spec-review benchmark 分析（2026-09-09，round 1–6）

資料：`data/index.jsonl` 58 runs、約 60 筆人工查證（verdicts 含私有 code 細節，未公開）。單一評審（Main OMP）對照 PR head commit 查證。
樣本：repo-a（個人 Go + React 聊天 app）#46 #49 #52 #53、repo-b（工作用 Go CRM service，fx DI + Postgres）#203 #204 #205 #206 #212，共 9 PR、2 repo，皆為私有。PR 編號保留以便對照 `index.jsonl`。
只有 `tree=pr-head` 的 round 4–5 是乾淨數據；round 1–3 的 reviewer 讀到的是 main 現況，recall 資料只能參考。

## 1. 每個模型的 precision / recall / 成本

| Reviewer | runs | 提出 | VERIFIED | REJECTED | INCONCLUSIVE | precision¹ | 命中 distinct² | 獨家³ | $ 總計 | $/run | wall 中位 | turns 中位 |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| Sonnet 5 (Pi) | 14 | 17 | 14 | 0 | 2 | 1.00 | 13 / 22 | 8 | 2.62 | 0.19 | 84s | 6 |
| Luna (Pi) | 17 | 25 | 18 | 0 | 7 | 1.00 | 12 / 22 | 6 | 0.16 | 0.009 | 54s | 5 |
| Gemini 3.7 Flash (Pi) | 19 | 6 | 4 | 1 | 1 | 0.80 | 3 / 22 | 1 | 0 | 0 | 24s | 5 |
| OMP 現況 (Gemini, 完整 prompt) | 1 | 0 | – | – | – | – | 0 / 22 | 0 | 0 | – | ~100s | 15 |
| OMP `--no-skills` (Gemini) | 1 | 1 | 1 | 0 | 0 | 1.00 | 1 / 22 | 1 | 0 | – | 35s | 7 |

¹ precision = VERIFIED / (VERIFIED + REJECTED)；INCONCLUSIVE 另計。
² distinct = 去重後所有 reviewer 聯集抓到的 22 個真問題；分母是「已知被抓到的」，不是「真實存在的」，所以這是相對 recall。
³ 只有該模型抓到。

**結論：**
- Sonnet 和 Luna 都沒有 false positive。差異在 Luna 會把 spec 語意兩讀的東西當 finding 提（7 個 INCONCLUSIVE 全是 `spec` 類：UI 元件「完整」的定義、「每個裝置」的粒度、SSR 時區），Sonnet 在 skill v2 後改走 `ambiguities`。
- **Sonnet 的獨家 finding 幾乎都是 high severity 且跨檔案**：DI 接錯 credential（wiring 檔 ↔ config 檔）、事件先 commit 再呼叫副作用、副作用失敗即永久遺失、WebSocket 缺 server-side ping、broadcast 無 membership 過濾、空測（assert 跟 setup 無關）。這些需要讀 diff 以外的檔案才能成立。
- **Luna 的獨家 finding 偏 spec 對照**：PR body 宣稱的欄位 / 錯誤碼 / 非同步 沒實作、`ON CONFLICT DO UPDATE` 漏更新某欄位。是「拿 PR body 逐句對 code」型。
- Gemini 在 repo-b 5 個 PR 全部 0 finding，repo-a 只在 #46 有產出。唯一獨家是 #46 一個 goroutine context 先 cancel 再 spawn worker 的 high（其他兩個都漏）。

## 2. Harness：Pi vs OMP 現況（同 model gemini-3.7-flash，同 packet，PR #46）

| | 首輪 input | turns | tool calls | 總 input(uncached) | cacheRead | findings |
|---|---:|---:|---:|---:|---:|---:|
| Pi 最小 harness（3 次平均） | 25K | 13 | 12 | 76K | 325K | 1–3 |
| OMP `--no-skills` + 同 system prompt | 30K | 7 | 6 | 55K | 196K | 1 |
| **OMP 現況** | **48K** | **15** | **14** | **115K** | **743K** | **0** |

- OMP 現況比 Pi 首輪多 23K（system prompt + skills 描述 + tool schema），cacheRead 多 2.3 倍，然後 0 finding。單次執行，但方向一致。
- Pi + Gemini 在 #46 三次 turns 分別 10/13/16，比 OMP-noskills 的 7 還多——Gemini 在薄 harness 裡反而更愛探索，省不到 token。**harness 變薄的收益取決於模型**：Luna 在 Pi 裡 3–5 turns 就結束，Sonnet 2–6。
- 因此原提案「換 Pi 省 token」對 Gemini 不成立，對 Luna/Sonnet 成立且主因是這兩個模型本來就少繞路。

### 2b. 分離 harness 與模型（round 6：OMP 現況 harness × Sonnet / Luna，pinned worktree）

| PR | Harness | Model | turns | tools | cacheRead | output | $ | findings | ✅ |
|---|---|---|---:|---:|---:|---:|---:|---:|---:|
| #46 | OMP 現況 | Sonnet | 5 | 5 | 318K | 11.8K | 0.39 | 4 | 4 |
| #46 | Pi | Sonnet（2 次） | 2 / 5 | 2 / 6 | 71K / 168K | 9.7K / 7.7K | 0.13 / 0.22 | 4 / 2 | 6 |
| #46 | OMP 現況 | Luna | 1 | 0 | 0 | 2.1K | 0.010 | 5 | 4 |
| #46 | Pi | Luna（3 次） | 3–5 | 6–8 | 42–86K | 2.6–3.2K | 0.010 | 4 / 4 / 5 | 12 |
| #203 | OMP 現況 | Sonnet | 6 | 5 | 410K | 9.9K | 0.40 | 3 | 2 (+1 ❓) |
| #203 | Pi | Sonnet | 7 | 6 | 222K¹ | – | 0.22 | 3 | 3 |
| #203 | OMP 現況 | Luna | 2 | 1 | 38K | 2.8K | 0.013 | 4 | 4 |
| #203 | Pi | Luna | 3 | – | – | – | 0.012 | 2 | 2 |

¹ Pi #203 Sonnet 的 cacheRead 從 index 取（`.usage.json`）。

- **OMP 現況 harness 配 Sonnet / Luna 都能正常產出，precision 一樣是 1.00。** round 1–2 OMP 現況 0 finding 的原因是 **Gemini**，不是 harness。原提案「harness 過重導致 review 失效」的診斷錯了一半：harness 重是事實，但失效主因是模型。
- OMP 現況下 Luna 甚至**更省**：#46 一輪 0 tool call 直接出 5 個 finding（4 ✅），因為 OMP 的 read tool 摘要 + 完整 packet 已經夠用；還多抓到 Pi 三次都沒抓到的「ws 無 server ping」和「`Body.Close` defer 在 retry loop 內」。#203 OMP+Luna 抓到「新 executor 只被 DI provide、沒有任何 consumer」和「E2E 傳 nil sender、dispatch 路徑沒跑到」，Pi+Luna 沒有。
- Sonnet 在 OMP 現況下 cacheRead 是 Pi 的 2–4 倍、$ 是 1.8–3 倍，finding 數量與內容相當。Sonnet 貴的部分是 harness 開銷，換 Pi 有實際節省；Luna 便宜到 harness 開銷無所謂。
- **修正後的結論**：換 harness 的收益是「Sonnet 省 40–60% 成本」，不是「讓 review 從 0 變有」。從 0 變有的關鍵是把 Gemini 換掉 + pin worktree。若不想維護 Pi 這條路徑，直接把 OMP reviewer agent 的模型從 `task` role（Gemini）改成 Luna/Sonnet，效果就出來。

## 3. Worktree pin 的影響

- round 1–3（讀 main）12 次 run 沒有任何一次抓到「Web Push 私鑰沒從 config 接進 service」；round 4 pin 到 PR head 後三個模型**全部**抓到。這是後續 PR #48 修的 production bug，是整個 benchmark 最強的 ground truth。
- Sonnet 在 #206 讀 main 時回報「diff 的 code path 不存在」——不是模型錯，是方法錯。
- **對 V1 的意義**：review 進行中 working tree 不能動，否則 reviewer 的 `read` 和 diff 對不上。session worktree 是必要條件，不是優化。

## 4. 方差（同 PR/模型多次）

| | 穩定度 |
|---|---|
| Luna | #46 4/4/5、#53 2/2/2、#52 1/1/0；內容高度重複。最穩。 |
| Sonnet | #212 1/0、#205 0/2、#46 4/2；內容互補而非重複（#46 兩次各抓到對方沒有的）。單次 run 不夠，要跑兩次或配 Luna。 |
| Gemini | #46 3/1/2，三次內容都不同，其中一次 hallucination（U+FFFD）。不可靠。 |

## 5. 成本模型（每 PR）

| 組合 | $ | wall（平行） | 預期 distinct 命中率⁴ |
|---|---:|---:|---:|
| Luna | 0.01 | ~55s | 12/22 = 55% |
| Luna + Sonnet | 0.20 | ~85s | 19/22 = 86%（去重後）|
| Luna + Sonnet + Gemini | 0.20 | ~85s | 20/22 = 91% |
| OMP 現況 ×1 | 0（訂閱） | ~100s | 0/22（n=1）|

⁴ 依本樣本。Main OMP 查證成本未量測：本次每個 finding 人工查證約 30s–2min，全部 45 筆約 40 分鐘，這是目前最大的隱藏成本。

## 6. 對 V1 的決定

1. **Luna 必跑**；**Sonnet 在 backend / 有 spec / touch config-auth-persistence 的 PR 必跑**；**Gemini 從 reviewer 移除**（0 precision 保證、repo-b 全空、$0 不足以補償）。若要保留 Gemini，只當「第三票」用來給 disagreement 加權，不看它的獨立輸出。
2. 原提案的「Sonnet 只處理 disagreement/critical」倒過來：Sonnet 是 recall 來源，不是仲裁者。仲裁者是 Main OMP 查證。
3. Risk router 暫時用兩條規則即可：touch backend 目錄 → +Sonnet；PR body 有 AC/spec 檔 → +Sonnet。
4. Luna 的 `spec` 類 finding 若 `confidence < 0.9` 或 claim 含「完整/所有/應該」這類語意詞，Main OMP 先當 ambiguity 處理，不進查證清單。或在 SKILL.md 再加一條硬規則後重測。
5. Packet 是 token 主成本（20–35K）；pathspec 排除 web/lockfile 已做；下一步是 `--test-cmd` 真的帶測試結果進 packet（目前全部 `(not run)`），因為 Sonnet #46 的「空測」和 #53 的「測試沒覆蓋非法輸入」都是靠讀測試檔抓到的，帶結果應該能更省 turns。
6. Herdr：目前 subprocess + DEVNULL 平行跑 18 個 reviewer 無問題。V1 不需要 Herdr；等要做 dashboard / 人工介入 blocked 狀態時再接。

## 7. 樣本限制

- n=9 PR、2 repo、同一個作者群；PR 大小 9K–111K bytes packet。
- recall 分母是聯集，真實漏抓數未知。唯一外部 ground truth 是 #46 → #47/#48 修的兩個 bug（Web Push 私鑰 wiring、env 透傳），前者三模型在 pinned 下都抓到，後者屬 deploy 層不在 packet 範圍。
- OMP 現況 baseline：Gemini 1 次（round 2）、Sonnet / Luna 各 2 次（round 6，§2b）。
- Sonnet 在 #205 的兩個 conf 0.5 效能疑慮、所有 `ambiguities` 未查證。
- 成本是 Pi 回報的數字；Anthropic 的 prompt 記在 cacheRead，Sonnet `input` 欄近 0 是正常的。
