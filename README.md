# Auralis Industrial Gateway

Puente de laboratorio para conectar ChatGPT/Universal MCP con dispositivos Modbus de forma controlada.

## Objetivo

Convertir el montaje manual de varias consolas en un arranque de una sola orden:

```text
Universal MCP -> Trinidad -> Cloudflare HTTPS -> Auralis Guard -> MCPO -> Modbus MCP -> dispositivo
```

La capa **Auralis Guard** es deliberadamente de solo lectura. El cliente no puede elegir una IP/puerto arbitrarios: solo puede usar dispositivos definidos en `config/devices.json` y rangos de registros previamente permitidos.

## Requisitos

- Windows 10/11
- `uv` / `uvx`
- `cloudflared`

El launcher comprueba que ambos comandos existan. Las versiones problemáticas que encontramos quedan fijadas automáticamente:

- `modbus-mcp==0.3.3`
- `fastmcp==3.4.6`
- `mcpo==0.0.20`
- `mcp==1.29.1`

## Uso

Arrancar todo con una sola orden:

```powershell
.\start.cmd
```

También puedes usar `./auralis-industrial.ps1 start` directamente desde PowerShell.

Ver estado:

```powershell
.\status.cmd
```

Parar todo:

```powershell
.\stop.cmd
```

El arranque muestra una URL `https://...trycloudflare.com` y la URL de OpenAPI que debe consumir Universal MCP:

```text
https://...trycloudflare.com/openapi.json
```

## Seguridad de laboratorio

Auralis Guard aplica:

- solo endpoints de lectura;
- lista cerrada de dispositivos;
- lista cerrada de rangos por dispositivo;
- máximo de registros por lectura;
- rate limit básico por IP;
- auditoría JSONL;
- no expone `write_register`, `write_coil`, `read_write_registers` ni operaciones equivalentes;
- no permite que el llamador proporcione `host`, `port` o `unit`.

Esto reduce de forma importante el riesgo de SSRF y de escrituras accidentales sobre equipos industriales.

## Configuración de dispositivos

Edita `config/devices.json`. Ejemplo:

```json
{
  "max_count": 64,
  "rate_limit_per_minute": 60,
  "devices": {
    "lab-sim": {
      "host": "45.8.248.56",
      "port": 502,
      "unit": 1,
      "register_ranges": [[40001, 40100]],
      "coil_ranges": [[1, 128]],
      "discrete_input_ranges": [[10001, 10128]]
    }
  }
}
```

Para una máquina real, sustituye el dispositivo de laboratorio por la IP, puerto, Unit ID y rangos documentados por el fabricante.

## Producción

El Quick Tunnel `trycloudflare.com` es solo para pruebas. Para un despliegue permanente conviene usar un Cloudflare Named Tunnel/Access o una VPN privada, mantener la capa Auralis en modo read-only por defecto y habilitar escrituras únicamente mediante políticas explícitas y confirmación humana.
