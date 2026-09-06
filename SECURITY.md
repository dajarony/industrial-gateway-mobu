# Security model

Este repositorio está diseñado como laboratorio read-only.

## Controles aplicados

1. **No expone operaciones Modbus de escritura.**
2. **No acepta host/port/unit desde el cliente.** Los destinos se resuelven por nombre desde `config/devices.json`.
3. **Allowlist de rangos.** Cada tipo de lectura debe caer completamente dentro de un rango permitido.
4. **Límite de tamaño de lectura.** `max_count` evita peticiones excesivas.
5. **Rate limit básico.** Mitiga abuso accidental o escaneo rápido.
6. **Auditoría.** Cada operación permitida o bloqueada se registra en `logs/audit.jsonl`.
7. **Trinidad sigue siendo una segunda capa.** Universal MCP puede continuar exigiendo confirmación humana.

## Riesgo residual

Un Quick Tunnel de Cloudflare sigue siendo una URL pública. Aunque Auralis Guard reduce la superficie y no permite escrituras, para producción debe sustituirse por un túnel autenticado/privado y políticas de identidad.

## Principio recomendado

Nunca habilitar una operación de escritura únicamente porque un fabricante la documente. Las escrituras deben tener una política separada por dispositivo, registro y valor, además de confirmación humana y pruebas en un entorno seguro.
