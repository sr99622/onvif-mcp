
sudo apt update
sudo apt install -y     git cmake ninja-build build-essential     libvulkan-dev mesa-vulkan-drivers     vulkan-tools glslc spirv-headers     libcurl4-openssl-dev
vulkaninfo --summary
git clone https://github.com/ggml-org/llama.cpp
cd llama.cpp
cmake -B build -G Ninja     -DCMAKE_BUILD_TYPE=Release     -DGGML_VULKAN=ON     -DLLAMA_CURL=ON
cmake --build build -j 8
./build/bin/llama-cli --list-devices
vulkaninfo --summary
./build/bin/llama-cli --list-devices
./build/bin/llama-cli     -hf Qwen/Qwen3-8B-GGUF:Q4_K_M     --device Vulkan0     -ngl 99     -c 4096
