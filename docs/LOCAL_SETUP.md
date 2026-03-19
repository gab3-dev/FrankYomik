# Running Frank Yomik Locally

Step-by-step guide to set up and run the full Frank Yomik translation system on your own machine.

## Prerequisites

| Dependency | Minimum Version | Purpose |
|------------|----------------|---------|
| Python | 3.12+ | Worker pipelines (OCR, translation, rendering) |
| Go | 1.21+ | API server |
| Redis | 7+ | Job queue and transient state |
| Ollama | latest | Local LLM for translation |
| Flutter | 3.11+ | Client app (optional, only if running the reader) |
| GPU | ~9 GB VRAM | Ollama (qwen3:14b) + OCR models |

Both NVIDIA (CUDA) and AMD (ROCm) GPUs are supported. See the [AMD GPU Setup](#amd-gpu-setup-rocm) section for AMD-specific instructions.

CPU-only is possible for development by setting `ocr.device: "cpu"` in `config.yaml` and using a smaller Ollama model, but translation quality and speed will suffer.

## Option 1: Native (no Docker)

This runs each component directly. You need three terminal sessions.

### 1. Install system dependencies

**Arch Linux:**
```bash
sudo pacman -S redis go python ollama
```

**Ubuntu/Debian:**
```bash
sudo apt-get install -y redis-server golang python3 python3-venv
# Ollama: https://ollama.ai/download
curl -fsSL https://ollama.ai/install.sh | sh
```

### 2. Pull the translation model

```bash
ollama pull qwen3:14b
```

This downloads ~9 GB. The model runs on your GPU via Ollama.

### 3. Set up the Python worker

```bash
cd server
python -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
pip install simple-lama-inpainting --no-deps   # must use --no-deps to avoid version conflicts
```

The first run will download ML models (~1.5 GB total for manga-ocr, RT-DETR-v2, and EasyOCR). These are cached in `~/.cache/huggingface/` and `~/.EasyOCR/`.

### 4. Start all services

Each command runs in its own terminal:

**Terminal 1 -- Redis:**
```bash
redis-server
```

**Terminal 2 -- Go API:**
```bash
cd server
AUTH_TOKEN=secret go run .
```

The API starts on `http://localhost:8080`. `AUTH_TOKEN` is required -- every API call must include `Authorization: Bearer secret`.

**Terminal 3 -- Python worker:**
```bash
cd server
source .venv/bin/activate
python -m worker --pipeline both
```

The `--pipeline` flag controls which pipelines the worker handles:
- `manga` -- manga_translate and manga_furigana only
- `webtoon` -- webtoon only
- `both` -- all pipelines (default for local dev)

### 5. Verify it works

```bash
# Health check (no auth required)
curl http://localhost:8080/api/v1/health

# Submit a test image
curl -X POST \
  -H "Authorization: Bearer secret" \
  -F "image=@docs/shounen.png" \
  -F "pipeline=manga_translate" \
  http://localhost:8080/api/v1/jobs
```

The response includes a `job_id`. Poll for completion:

```bash
curl -H "Authorization: Bearer secret" \
  http://localhost:8080/api/v1/jobs/<job_id>
```

When status is `completed`, download the result:

```bash
curl -H "Authorization: Bearer secret" \
  http://localhost:8080/api/v1/jobs/<job_id>/image -o result.png
```

## Option 2: Docker Compose

This is the standard deployment path. Requires Docker with the NVIDIA Container Toolkit for GPU access.

### 1. Configure environment

```bash
# Create .env in the project root
echo "AUTH_TOKEN=mysecret" > .env

# Match container UID/GID to your host user (avoids cache permission issues)
echo "APP_UID=$(id -u)" >> .env
echo "APP_GID=$(id -g)" >> .env
```

### 2. Build and start

```bash
docker compose up -d
```

This starts five services:
- **redis** -- message queue
- **ollama** -- LLM inference (auto-pulls `qwen3:14b` on first run)
- **api** -- Go API server on port 8080
- **worker** -- Python processing worker
- **cloudflared** -- Cloudflare tunnel for remote access (optional, requires `.cloudflared/` config)

### 3. Monitor startup

```bash
# Watch worker logs (first run downloads ML models, takes a few minutes)
docker compose logs -f worker

# Verify health
curl -H "Authorization: Bearer mysecret" http://localhost:8080/api/v1/health
```

### 4. Useful Docker commands

```bash
# Restart just the worker after config changes
docker compose restart worker

# View Ollama logs
docker compose logs -f ollama

# Shell into the worker container
docker compose exec worker bash

# Rebuild after code changes
docker compose up -d --build

# Full reset (removes volumes, re-downloads models)
docker compose down -v
```

## Option 3: CLI (no server)

Process images directly without running the web service. Useful for batch processing or testing.

```bash
cd server
source .venv/bin/activate

# Make sure Ollama is running
ollama serve &

# Manga: translate Japanese to English
python process_manga.py translate

# Manga: add furigana readings
python process_manga.py furigana

# Both pipelines + debug bounding box overlay
python process_manga.py all --debug

# Webtoon: download and translate a Naver Webtoon chapter
python process_webtoon.py pipeline <NAVER_CHAPTER_URL>
```

Input images: `docs/adult*.png` (furigana), `docs/shounen*.png` (translation).
Output: `output/furigana/`, `output/translate/`.

## Flutter Client

The client app wraps Kindle and Naver Webtoon in a WebView, captures pages, and overlays translated images.

### Linux desktop dependencies

**Arch Linux:**
```bash
sudo pacman -S gtk3 webkit2gtk-4.1 sqlite ninja clang cmake
```

**Ubuntu/Debian:**
```bash
sudo apt-get install -y \
  libgtk-3-dev \
  libwebkit2gtk-4.1-dev \
  libsqlite3-dev \
  ninja-build \
  pkg-config \
  clang \
  cmake
```

### Build and run

```bash
cd client
flutter pub get
flutter run -d linux
```

On first launch, open Settings and configure:
- **Server URL**: `http://localhost:8080` (default)
- **Auth token**: the same `AUTH_TOKEN` you set for the API

### Android

```bash
cd client
flutter build apk --release
```

Transfer the APK to your phone. You need to enable "Install from unknown sources" for your file manager. On Samsung devices, also disable Auto Blocker (Settings > Security > Auto Blocker).

The app allows cleartext HTTP to local addresses (192.168.x.x, 10.x.x.x, localhost) for LAN use without HTTPS.

## Configuration

All worker/pipeline settings are in `server/config.yaml`.

### Key settings

```yaml
ollama:
  url: "http://localhost:11434"       # Ollama API (or http://ollama:11434 in Docker)
  translate_model: "qwen3:14b"        # LLM model for translation
  translate_options:
    temperature: 0.3                  # Lower = more consistent translations
    num_predict: 1024                 # Max tokens per translation
    think: false                      # Disable thinking mode for qwen3
  review_pass: false                  # Enable context-aware review of translations

ocr:
  device: "cuda"                      # "cuda" for GPU (~350MB VRAM); "cpu" if tight on VRAM

text_detection:
  gpu: true                           # EasyOCR GPU acceleration

webtoon:
  inpainting:
    enabled: true                     # LaMa text removal before rendering
    model: "lama"
```

### Environment variables

| Variable | Required | Default | Description |
|----------|----------|---------|-------------|
| `AUTH_TOKEN` | Yes | -- | Bearer token for API authentication |
| `REDIS_URL` | No | `redis://localhost:6379` | Redis connection string |
| `CACHE_DIR` | No | `./cache` | Disk cache path for processed images |
| `OLLAMA_BASE_URL` | No | `http://localhost:11434` | Overrides `config.yaml` Ollama URL |

## Running Tests

```bash
# Python unit tests
cd server
source .venv/bin/activate
PYTHONPATH=. pytest tests/unit/ -v

# Single test file
PYTHONPATH=. pytest tests/unit/test_translator.py -v

# Single test method
PYTHONPATH=. pytest tests/unit/test_page_cache.py::TestPageCacheV2::test_store_page -v

# Integration tests (requires test images in docs/)
PYTHONPATH=. pytest tests/integration/ -v

# Go API tests (Redis-dependent tests skip gracefully without Redis)
cd server && go test -v .

# Single Go test
cd server && go test -run TestHandleJobSubmit -v .

# Flutter tests
cd client && flutter test

# Single Flutter test file
cd client && flutter test test/services/api_service_test.dart

# Flutter static analysis
cd client && flutter analyze
```

## AMD GPU Setup (ROCm)

Frank Yomik works on AMD GPUs with zero Python code changes. All GPU-accelerated components use PyTorch, which exposes the same `torch.cuda.*` API on both NVIDIA (CUDA) and AMD (ROCm) backends.

### Tested hardware

| GPU | VRAM | Ollama | OCR Models | Notes |
|-----|------|--------|------------|-------|
| RX 6750 XT (gfx1031) | 12 GB | qwen3:8b (5 GB) | All on GPU | Tested, fully working |
| RX 7900 XTX | 24 GB | qwen3:14b (9 GB) | All on GPU | Should work |
| RX 7800 XT | 16 GB | qwen3:14b (9 GB) | All on GPU | Should work |
| RX 6700 XT | 12 GB | qwen3:8b (5 GB) | All on GPU | Same arch as 6750 XT |
| RX 7600 | 8 GB | qwen3:8b (5 GB) | OCR on CPU | Tight VRAM, set `ocr.device: "cpu"` |

### 1. Install ROCm

**Arch Linux:**
```bash
# ROCm is available in the official repos
sudo pacman -S rocm-hip-runtime rocm-smi-lib
```

**Ubuntu/Debian:**
```bash
# Follow AMD's official guide:
# https://rocm.docs.amd.com/projects/install-on-linux/en/latest/
```

Verify ROCm detects your GPU:
```bash
rocminfo | grep "Marketing Name"
# Should show: AMD Radeon RX 6750 XT (or your GPU)
```

### 2. Set HSA_OVERRIDE_GFX_VERSION

RDNA2 GPUs (RX 6000 series) need a GFX version override because PyTorch and Ollama's bundled ROCm libraries target specific architecture IDs.

| GPU Family | GFX ID | Override Value |
|------------|--------|---------------|
| RX 6700/6750/6800 | gfx1031 | `10.3.0` |
| RX 6900 | gfx1030 | `10.3.0` |
| RX 7600/7700/7800/7900 (RDNA3) | gfx1100/1101/1102 | Usually not needed |

Add to your shell profile (`~/.bashrc` or `~/.zshrc`):
```bash
export HSA_OVERRIDE_GFX_VERSION=10.3.0
```

### 3. Configure Ollama for ROCm

Ollama's systemd service needs the same override:

```bash
sudo mkdir -p /etc/systemd/system/ollama.service.d
sudo tee /etc/systemd/system/ollama.service.d/rocm.conf << 'EOF'
[Service]
Environment="HSA_OVERRIDE_GFX_VERSION=10.3.0"
EOF
sudo systemctl daemon-reload
sudo systemctl restart ollama
```

Verify Ollama uses the GPU:
```bash
ollama run qwen3:latest "say OK"
ollama ps
# Should show: 100% GPU
```

### 4. Install PyTorch with ROCm

The standard PyTorch pip package is CPU-only. Install the ROCm build:

```bash
pip install torch torchvision --index-url https://download.pytorch.org/whl/rocm6.3 --force-reinstall --no-cache-dir
```

Verify:
```bash
python3 -c "import torch; print('ROCm:', torch.version.hip); print('GPU:', torch.cuda.get_device_name(0))"
# Should show: ROCm: 6.3.x  GPU: AMD Radeon Graphics
```

### 5. Choose the right Ollama model

With 12 GB VRAM (e.g. RX 6750 XT), `qwen3:14b` (~9 GB) leaves almost no room for OCR models. Use `qwen3:latest` (8B, ~5 GB) instead:

```bash
ollama pull qwen3:latest
```

Update `server/config.yaml`:
```yaml
ollama:
  translate_model: "qwen3:latest"    # 8B fits in 12 GB alongside OCR models
```

With 16+ GB VRAM, `qwen3:14b` fits comfortably.

### 6. Start the services

Same as the standard setup, but ensure the GFX override is set for the worker:

```bash
# Terminal 1 — Redis
redis-server

# Terminal 2 — Go API
cd server && AUTH_TOKEN=secret go run .

# Terminal 3 — Python worker (HSA override required for RDNA2)
cd server && HSA_OVERRIDE_GFX_VERSION=10.3.0 python -m worker --pipeline both
```

No changes to `config.yaml` are needed — `device: "cuda"` and `gpu: true` work as-is because PyTorch ROCm maps the CUDA API transparently.

### Why no code changes are needed

Every GPU-using component in Frank Yomik uses standard PyTorch APIs:
- `torch.cuda.is_available()` — returns `True` on ROCm
- `.to("cuda")` — works identically on ROCm
- `torch.cuda.empty_cache()` — maps to HIP memory management

The ROCm PyTorch build is a drop-in replacement. Ollama also has native ROCm support built into its bundled libraries.

## Troubleshooting

### Worker won't start / model download hangs

The first worker run downloads manga-ocr (~400 MB), RT-DETR-v2 (~130 MB), and EasyOCR models (~100 MB). Ensure you have internet access and enough disk space. Models cache to:
- `~/.cache/huggingface/` (manga-ocr, RT-DETR-v2)
- `~/.EasyOCR/` (EasyOCR language models)

### GPU out of memory (NVIDIA or AMD)

Ollama's qwen3:14b needs ~9 GB VRAM. manga-ocr adds ~350 MB. If tight:
1. Set `ocr.device: "cpu"` in `config.yaml` (frees ~350 MB VRAM)
2. Use a smaller Ollama model: `ollama pull qwen3:8b` and update `config.yaml`
3. On 12 GB cards (RX 6750 XT, RTX 3060), use `qwen3:latest` (8B) instead of 14b

### Ollama running on CPU instead of GPU (AMD)

Check `ollama ps` — if it shows `100% CPU`:
1. Verify ROCm detects the GPU: `rocminfo | grep "Marketing Name"`
2. Check Ollama logs: `journalctl -u ollama | grep -i "gpu\|error\|rocm"`
3. If you see `failure during GPU discovery`, set `HSA_OVERRIDE_GFX_VERSION` in the Ollama service (see [AMD GPU Setup](#3-configure-ollama-for-rocm))
4. Ensure the `ollama` user is in the `render` and `video` groups: `getent group render video`

### PyTorch not detecting AMD GPU

If `torch.cuda.is_available()` returns `False`:
1. Verify you installed the ROCm build: `python3 -c "import torch; print(torch.version.hip)"`  — if it prints `None`, you have the CPU/CUDA build
2. Reinstall: `pip install torch --index-url https://download.pytorch.org/whl/rocm6.3 --force-reinstall`
3. Set `HSA_OVERRIDE_GFX_VERSION=10.3.0` for RDNA2 GPUs

### Job stuck at "queued"

1. Check the worker is running and connected: look for `Connected to Redis` in worker logs
2. Check Redis is reachable: `redis-cli ping` should return `PONG`
3. Check Ollama is running: `curl http://localhost:11434/api/tags`

### Permission errors on cache directory

Docker containers run as `APP_UID:APP_GID` (default 1026). If cache files have wrong ownership:

```bash
# Fix manually
sudo chown -R $(id -u):$(id -g) cache/

# Or set APP_UID/APP_GID in .env to match your host user
echo "APP_UID=$(id -u)" >> .env
echo "APP_GID=$(id -g)" >> .env
docker compose up -d
```

### Flutter WebView blank or not loading

On Linux, ensure `libwebkit2gtk-4.1-dev` is installed. The WebView requires a Wayland or X11 session (won't work in headless/SSH without display forwarding).

### Cloudflare Tunnel (remote access)

To expose the API over HTTPS for remote Flutter clients:

```bash
# One-time setup
cloudflared tunnel login
cloudflared tunnel create yomik
cloudflared tunnel route dns yomik your-hostname.example.com
```

Create `.cloudflared/config.yml`:
```yaml
tunnel: <TUNNEL_UUID>
credentials-file: /etc/cloudflared/<TUNNEL_UUID>.json

ingress:
  - hostname: your-hostname.example.com
    service: http://api:8080
  - service: http_status:404
```

Copy credentials from `~/.cloudflared/<TUNNEL_UUID>.json` into `.cloudflared/`, then `docker compose up -d`. The `cloudflared` service connects automatically.
