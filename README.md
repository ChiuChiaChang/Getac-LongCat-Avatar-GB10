# Getac LongCat Avatar GB10 v1.0.1.0

一鍵部署 **LongCat-Video-Avatar 1.5**，在 NVIDIA GB10（DGX Spark / Linux ARM64）使用 **PNG/JPG + WAV** 產生 AI 主播 MP4。

> **狀態：尚未在使用者的 GB10 實機測試。** 安裝腳本成功或 API 健康檢查成功，不代表模型一定可順利推論。首次測試請使用 3–5 秒 WAV。

## 安裝

需求：ARM64 Linux、NVIDIA Driver、Docker Engine、Docker Compose v2、NVIDIA Container Toolkit、足夠 SSD 空間（建議預留至少 200 GiB，視模型實際下載而定）。

```bash
git clone https://github.com/ChiuChiaChang/Getac-LongCat-Avatar-GB10.git
cd Getac-LongCat-Avatar-GB10
chmod +x *.sh
./install.sh
```

預設 Swagger：`http://GB10-IP:8500/docs`

測試（先自行準備正面主播圖與 WAV）：

```bash
./test.sh presenter.png speech.wav output.mp4
```

## Fix: LocalAI POST /video returns 404 (v1.0.1.0)

The official LocalAI video endpoint **is** `POST /video` (not `/v1/video`). An HTTP 404 on `longcat-core:8080/video` indicates that the current LocalAI runtime may not include the video route. The previous `/health` endpoint only checked general backend readiness, which was insufficient.

Update and repair on GB10:

```bash
git pull
chmod +x *.sh
./fix-video-api.sh
curl -s http://127.0.0.1:8500/health
```

Starting with v1.0.1.0, `/health` reports `backend_ready`, `video_api_ready`, `model_installed` independently. When the POST route is present, `GET /video` should return HTTP **405 Method Not Allowed**, not 404. Model installation and GPU inference still require validation.

The repair script pins the current supported DGX Spark CUDA 13 ARM64 image, backs up `.env`, restarts **only the two LongCat containers**, and preserves `data/models` and `data/jobs`. It does not stop other Getac services on ports 8100–8400.

## API

- `GET /health`：LocalAI 服務就緒狀態，**不是 GPU 推論成功證明**
- `POST /api/presenter/create`：multipart 欄位 `avatar` 或 `image` + `audio` WAV；`prompt` 可選
- `GET /api/presenter/status/{job_id}`
- `GET /api/presenter/result/{job_id}`
- `GET /api/presenter/log/{job_id}`

```bash
./logs.sh
./stop.sh
```

## 注意

- 本專案使用 LocalAI CUDA 13 ARM64 容器、LongCat 模型；**與現有 EchoMimic 8300、LivePortrait 8400 獨立**。
- 模型生成的是**不透明 MP4**；若需和 PPT 合成透明人物，仍須另外去背，保留 Alpha。
- `.env.example` 可複製成 `.env` 自行修改。API 預設對 LAN 綁定 `0.0.0.0:8500`，請設定 `GETAC_API_KEY` 或限制防火牆/VPN，**不要公開未保護的 Port 8500**。
- `data/models` 與 `data/jobs` 不提交 GitHub。
- 模型及第三方軟體授權請見 `LICENSE-THIRD-PARTY.md`。

## 來源

- 模型： https://huggingface.co/meituan-longcat/LongCat-Video-Avatar-1.5
- 官方程式： https://github.com/meituan-longcat/LongCat-Video
- LocalAI： https://localai.io/docs/features/video-generation/

版本：**1.0.0.0**。
