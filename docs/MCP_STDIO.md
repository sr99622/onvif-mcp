This text should be added to the .hermes/config.yaml

```
mcp_servers:
  camera:
    command: uv
    args:
    - --directory
    - {{HOME}}/Projects/onvif-mcp/packages/stdio/src
    - run
    - camera.py
    enabled: true
    env:
      CAMERA_USERNAME: {{USERNAME}}
      CAMERA_PASSWORD: {{PASSWORD}}
      STREAM_SERVER_URL: {{SERVER_FQDN}}
```