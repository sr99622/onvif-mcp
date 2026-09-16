# Client configuration

### Qwen3.6 35B

```yaml
model:
  default: unsloth/Qwen3.6-35B-A3B-GGUF-Q4_K_XL
  provider: custom
  base_url: http://10.1.1.2:8080/v1
  supports_vision: true
  
custom_providers:
  - name: flexi
    base_url: http://10.1.1.2:8080/v1
    model: unsloth/Qwen3.6-35B-A3B-GGUF-Q4_K_XL
    models:
      unsloth/Qwen3.6-35B-A3B-GGUF-Q4_K_XL:
        context_length: 209398
```

### Qwen3.8 27B

```yaml
model:
  default: williamliao/Qwen3.8-27B-NVFP4-GGUF
  provider: custom
  base_url: http://10.1.1.2:8080/v1
  supports_vision: true

custom_providers:
  - name: flexi
    base_url: http://10.1.1.2:8080/v1
    model: williamliao/Qwen3.8-27B-NVFP4-GGUF
    models:
      williamliao/Qwen3.8-27B-NVFP4-GGUF:
        context_length: 209398
```

&nbsp;
&nbsp;

# Run Model on Windows Server (PowerShell)

&nbsp;

### Qwen3.8 27B NVIDIA BUILD

```powershell
cd Projects/llama.cpp

$env:LLAMA_CACHE="unsloth/Qwen3.8-27B-GGUF"

.\build\bin\Release\llama-server.exe -hf williamliao/Qwen3.8-27B-NVFP4-GGUF --temp 1.0 --top-p 0.95 --top-k 20 --presence_penalty 1.5 --min-p 0.00 --host 10.1.1.2 --port 8080 --ctx-size 209398 --n-gpu-layers 999 --jinja --cache-type-k q8_0 --cache-type-v q8_0 --spec-type draft-mtp --spec-draft-n-max 3 --reasoning-format deepseek --reasoning-effort medium -fa on --mmproj C:\Users\sr996\Projects\llama.cpp\mmproj-F16.gguf
```

### Qwen3.8 27B UNSLOTH BUILD

```powershell
cd Projects/llama.cpp

$env:LLAMA_CACHE="unsloth/Qwen3.8-27B-GGUF"

 .\build\bin\Release\llama-server.exe -hf unsloth/Qwen3.8-27B-GGUF:UD-Q4_K_M --temp 1.0 --top-p 0.95 --top-k 20 --presence_penalty 1.5 --min-p 0.00 --host 10.1.1.2 --port 8080 --ctx-size 209398 --n-gpu-layers 999 --jinja --cache-type-k q8_0 --cache-type-v q8_0
```


### Qwen3.6 35B

```powershell
$env:LLAMA_CACHE="unsloth\Qwen3.6-35B-A3B-GGUF"

build\bin\Release\llama-server.exe -hf unsloth/Qwen3.6-35B-A3B-GGUF:UD-Q4_K_XL --temp 1.0 --top-p 0.95 --top-k 20 --presence_penalty 1.5 --min-p 0.00 --host 10.1.1.2 --port 8080 --ctx-size 262144 --n-gpu-layers 999 --jinja
```


&nbsp;
# Fast Qwen3.8 

https://xhinker.medium.com/100-tokens-second-on-one-rtx-3090-ti-qwen3-8-27b-full-262k-context-one-gpu-1451b1e25fb0

git clone -b main https://github.com/JakeATX/llamAmpere.git
cd llamAmpere
cmake -S . -B build-sm120 -DCMAKE_BUILD_TYPE=Release -DGGML_CUDA=ON -DGGML_CUDA_FA=ON \
      -DCMAKE_CUDA_ARCHITECTURES=120 -DGGML_NATIVE=ON
cmake --build build-sm120 -j8 --target llama-server

mkdir -p ~/models/qwen38-27b-atx
wget -O ~/models/qwen38-27b-atx/Qwen3.8-ATX-4-XS.gguf \
  "https://huggingface.co/jakeatx/Qwen3.8-27B-ATX-IQ4_XS-M-GGUF/resolve/main/Qwen3.8-ATX-4-XS.gguf"

CUDA_VISIBLE_DEVICES=0 GGML_Q8_TURBO3_MMA_FUSED=1 \
/home/stephen/Projects/llamAmpere/build-sm120/bin/llama-server \
    -m /home/stephen/models/qwen38-27b-atx/Qwen3.8-27B-ATX-4-XS.gguf \
    --alias Qwen3.8-27B-GGUF \
    -c 262144 -b 4096 -ub 1024 -t 8 -tb 8 -ngl 99 -fa on -ctk q8_0 -ctv turbo3 \
    --parallel 1 --jinja --fit off \
    --cache-prompt --cache-ram 8192 --ctx-checkpoints 24 --checkpoint-min-step 10240 \
    --spec-type draft-mtp --spec-draft-n-max 3 --spec-draft-p-min 0 \
    --spec-draft-type-k q8_0 --spec-draft-type-v q8_0 \
    --host 0.0.0.0 --port 8082 \
    --spec-draft-vocab-map docs/mtp-vocab/atx_65536.txt



