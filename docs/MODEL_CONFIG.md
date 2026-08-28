# Client configuration

### Qwen3.6 35B

```yaml
model:
  default: unsloth/Qwen3.6-35B-A3B-GGUF-Q4_K_XL
  provider: custom
  base_url: http://10.1.1.2:8080/v1

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

```
cd Projects/llama.cpp

$env:LLAMA_CACHE="unsloth/Qwen3.8-27B-GGUF"

.\build\bin\Release\llama-server.exe -hf williamliao/Qwen3.8-27B-NVFP4-GGUF --temp 1.0 --top-p 0.95 --top-k 20 --presence_penalty 1.5 --min-p 0.00 --host 10.1.1.2 --port 8080 --ctx-size 209398 --n-gpu-layers 999 --jinja --cache-type-k q8_0 --cache-type-v q8_0 --spec-type draft-mtp --spec-draft-n-max 3 --reasoning-format deepseek --reasoning-effort medium -fa on --mmproj C:\Users\sr996\Projects\llama.cpp\mmproj-F16.gguf
```

### Qwen3.8 27B UNSLOTH BUILD

```
cd Projects/llama.cpp

$env:LLAMA_CACHE="unsloth/Qwen3.8-27B-GGUF"

 .\build\bin\Release\llama-server.exe -hf unsloth/Qwen3.8-27B-GGUF:UD-Q4_K_M --temp 1.0 --top-p 0.95 --top-k 20 --presence_penalty 1.5 --min-p 0.00 --host 10.1.1.2 --port 8080 --ctx-size 209398 --n-gpu-layers 999 --jinja --cache-type-k q8_0 --cache-type-v q8_0
```


### Qwen3.6 35B

```
$env:LLAMA_CACHE="unsloth\Qwen3.6-35B-A3B-GGUF"

build\bin\Release\llama-server.exe -hf unsloth/Qwen3.6-35B-A3B-GGUF:UD-Q4_K_XL --temp 1.0 --top-p 0.95 --top-k 20 --presence_penalty 1.5 --min-p 0.00 --host 10.1.1.2 --port 8080 --ctx-size 262144 --n-gpu-layers 999 --jinja
```


&nbsp;

---

</details>