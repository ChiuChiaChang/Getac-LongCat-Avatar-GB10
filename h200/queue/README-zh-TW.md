# Getac LongCat Gateway FIFO Queue v1.1.0.0

適用：既有 H200 `~/Getac-LongCat-Avatar-H200`、原有 `getac-longcat-h200-core`、`getac-longcat-h200-api`、GetacPPTAIStudio v1.3.1.45、GB10 (需不同部署指令)。

## 功能

- `/api/presenter/create` 保持相容；接受多個工作並回 HTTP 202，不因 GPU 忙碌回 HTTP 429。
- **GPU 一次一個工作**，其他工作依進來時間 FIFO 排隊；最多 `GETAC_QUEUE_MAX_PENDING` 個等待中的工作（預設 50），超過才回 429。
- `/api/presenter/status/{job_id}` 除舊有 `status`、`progress`、`message` 外，新增 `queue_position`、`jobs_ahead`、`queue_length`、`elapsed_seconds`、`estimated_wait_seconds`。
- `/api/presenter/queue`（需 `X-API-Key`）看整體排隊數和工作狀態。
- `/api/presenter/cancel/{job_id}`（POST，需 Key）取消**尚未開始**的工作；正在 GPU 推論的工作不可取消。
- 成功完成 >=3 筆後，以最近 20 筆成功工作耗時的中位數估算等待時間；未有足夠樣本時 `estimated_wait_seconds: null`，避免虛構。
- 待處理工作寫在原本掛載的 `data/jobs/`，Gateway 重啟後會復原排隊工作。**正在推論的工作若遇 Gateway 重啟，會標成 failed，不會自動再次執行，避免重複占用 GPU。**
- 保留既有 `GETAC_API_KEY` 與 `X-API-Key`，所有 Job 狀態仍需驗證。Queue 不會保存 API Key。
- `progress: 25` 仍只是「推論中」的**階段標記**，不是 GPU 真實完成百分比。

## 從 GitHub 部署（H200，不改 Qwen / Core）

1. **先確認 GetacPPTAIStudio 沒有正在生成影片；不要中斷 GPU 推論。**
2. 在 H200 執行：

```bash
cd ~/Getac-LongCat-Avatar-H200
git pull --ff-only
bash h200/queue/deploy-h200-queue.sh /home/essw/Getac-LongCat-Avatar-H200
```

此腳本先備份 `gateway/app.py`，然後執行：

```bash
sudo docker compose -f docker-compose.h200.yml up -d --no-deps --build gateway
```

**不會重建 `longcat-core`，不會改 Qwen 30001，不會重新下載 `/models`，不會覆寫 `.env` 或 H200 Compose。**

如果原本有任一 Job `status=running`，腳本拒絕部署。請確認是否仍在跑，之後再更新。

## 確認新版本

```bash
curl -s http://127.0.0.1:8500/health | python3 -m json.tool
# 預期 version=1.1.0.0, queue_enabled=true

sudo docker logs -f --tail 100 getac-longcat-h200-api
```

## 查看 Job 排隊

Windows Studio 原本的上傳、查詢、下載 MP4 功能不需修改；若仍使用 v1.3.1.45，只會顯示 queued、running 等狀態，不會自動呈現新增的排隊順位 UI。建議使用 GetacPPTAIStudio v1.3.1.46。

在 H200 直接查看最新狀態（不需印出密鑰）：

```bash
cd ~/Getac-LongCat-Avatar-H200
find data/jobs -name status.json -printf '%T@ %p\n' | sort -nr | head -5
# 找到 Job ID 後：
cat data/jobs/<JOB_ID>/status.json
```

動態 `queue_position` 等欄位需呼叫 API，請在自己的用戶端使用 `X-API-Key`：

```text
GET http://<H200-IP>:8500/api/presenter/status/<JOB_ID>
Header: X-API-Key: <private-key>
```

例：第 3 位排隊者可能看到：

```json
{
  "job_id": "...",
  "status": "queued",
  "progress": 0,
  "queue_position": 3,
  "jobs_ahead": 3,
  "queue_length": 4,
  "elapsed_seconds": 90,
  "estimated_wait_seconds": null
}
```

`jobs_ahead` 包含當前正在推論的工作；無歷史樣本時 ETA 為 null。

## 回復原版

部署腳本會顯示備份路徑；待沒有影片在生成時：

```bash
cd ~/Getac-LongCat-Avatar-H200
cp gateway/app.py.before_queue_<時間戳> gateway/app.py
sudo docker compose -f docker-compose.h200.yml up -d --no-deps --build gateway
```

## 測試

- `tests/test_queue.py` 是離線模擬，驗證五人 FIFO、不可同時雙推論、401 認證、取消、重啟回復待處理工作。
- 實機仍必須用相同短 WAV 驗證影片生成與 Qwen 共用 GPU 的 VRAM。
- **單一 Gateway 只能用 1 個 Uvicorn worker/Compose replica**；若要多份 Gateway 複本，需改成 Redis/資料庫分散式工作佇列。
- 此版沒有多機 GB10 + H200 統一排程；每台 Gateway 是獨立一條佇列。
- 此版沒有長 WAV 自動分段、沒有真實 GPU 推論百分比。 `max_segments` 維持原本 API 格式，不保證會實際切片。
