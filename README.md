# RutaTaller · Grupo 2 · Caso práctico #2

Qué órdenes conviene mandar a segunda revisión antes del cierre, considerando el riesgo de reingreso y la holgura del plazo prometido.

## Cómo correrlo

1. En SQL Server (SSMS o Azure Data Studio), ejecutar en orden:
   1. `sql/01_crear_tablas.sql`: crea dentro de la base `ajomuch92_ruta_taller` (ya existente) los esquemas `stg`, `dw` y `etl` y sus tablas.
   2. `sql/02_transformar.sql`: crea el procedimiento `etl.usp_transformar`.
   3. `sql/03_reglas.sql`: crea las reglas, el procedimiento `dw.usp_simular_reglas` y la vista `dw.vResumenRegla`.
2. Copiar `.env.example` a `.env` y poner las credenciales.
3. Cargar los datos:
   ```bash
   pip install -r etl/requirements.txt
   python etl/cargar.py
   ```
   El script carga los 5 archivos a `stg`, ejecuta `etl.usp_transformar` y `dw.usp_simular_reglas`, y al final imprime los controles y el resumen de las reglas.
4. `sql/04_controles_y_kpi.sql`: contiene las consultas de evidencia (conteos, controles, línea base y las 2 verificaciones de KPI). Hay que tomar capturas de sus resultados.
5. En Power BI, conectarse a `ajomuch92_ruta_taller` (ver la sección Power BI).

## Modelo (estrella)

```
                 DimFecha (FechaKey, Fecha, Mes, Dia_semana, Periodo)
                  │                         │
DimFamilia ── FactEvento ──────────── FactCapacidad
(FamiliaKey)  (Evento_ID, grano: orden)  (FechaKey+CentroKey, grano: centro-día)
                  │      │                  │
                  │      └──── DimCentro ───┘   (dimensión compartida)
                  │
          ResultadoRegla (ReglaKey + Evento_ID) ── DimRegla (regla × escenario de capacidad)
```

- Los dos hechos comparten `DimFecha` y `DimCentro`.
- La capacidad se suma **en su propio grano** (centro-día). Si se uniera a los eventos antes de sumarla, se multiplicaría por las ~13.5 órdenes de cada día. El control `Capacidad` de `etl.Control` muestra ambas cifras.

## Transformaciones (procedimiento `etl.usp_transformar`)

| # | Transformación | Qué hace | Control registrado |
|---|---|---|---|
| T1 | Limpieza de claves | `UPPER(LTRIM(RTRIM()))` en Centro_ID y Familia_ID (`' c03 '` → `C03`) | Claves corregidas |
| T2 | Limpieza de fechas | Convierte `yyyy-mm-dd` (estilo 23) y `dd/mm/yyyy` (estilo 103) a `DATE` | 40 fechas dd/mm convertidas, 0 sin convertir |
| T3 | Conversión de tipos | Texto → `TINYINT`/`DECIMAL`/`BIT` con `TRY_CONVERT` | 0 valores sin convertir |
| T4 | Deduplicación | `DISTINCT` sobre la fila completa; Evento_ID único | 10,010 → 10,000 (10 copias) |
| T5 | Control de rangos | Complejidad 1-5, horas ≥ 0, conteos ≥ 0, reingreso 0/1, costo = 0 cuando no hubo reingreso, fecha jul-oct | 0 fuera de rango |
| T6 | Validación de relaciones | Cada evento debe tener centro, familia, fecha y capacidad del centro-día | 0 huérfanos; 738 filas de capacidad |
| T7 | Campos derivados | `Holgura_h`, `Holgura_post_rev_h`, `Pierde_holgura`, `Puntaje_riesgo`, `Periodo`, `Cupos_revision` | Conteos de holgura |

> Ojo con las fechas: si se interpretan con "día primero" para todas las filas, las fechas ISO con día ≤ 12 se voltean y aparecen eventos en enero-junio. Por eso cada formato se convierte con su estilo explícito.

## Reglas (detalle en `sql/03_reglas.sql`)

- **Puntaje_riesgo** = 2·(fallas ≥ 2) + 1·(fallas = 1) + 2·(complejidad ≥ 4). Solo usa campos conocidos al momento de decidir.
- **Regla A · Riesgo técnico:** son candidatas las órdenes con fallas ≥ 2 o complejidad ≥ 4, ordenadas por puntaje.
- **Regla B · Riesgo con holgura:** las candidatas de A que conservan holgura ≥ 0 después de la revisión.
- **Desempate:** fallas DESC, complejidad DESC, Evento_ID ASC.
- **Capacidad:** en cada centro y día se atienden las primeras `FLOOR(min_disponibles × factor / min_evento)` órdenes, con factor 1.00 o 0.80.
- `Reingreso_30d` y `Costo_retrabajo_L` **no** entran en las reglas. Solo se usan para medir la cobertura.

## Power BI

1. **Obtener datos** → SQL Server → `ajomuch92_ruta_taller` en modo Import. Tablas a importar:
   - `dw.DimFecha`, `dw.DimCentro`, `dw.DimFamilia`, `dw.DimRegla`
   - `dw.FactEvento`, `dw.FactCapacidad`, `dw.ResultadoRegla`
2. **Relaciones** (1:* y filtro en una sola dirección):
   - Las dimensiones filtran a `FactEvento` y a `FactCapacidad` (Fecha y Centro).
   - `FactEvento[Evento_ID]` 1:* `ResultadoRegla[Evento_ID]`.
   - `DimRegla` 1:* `ResultadoRegla`.
3. Las medidas DAX están en `powerbi/medidas.dax`.
4. Páginas del reporte:
   - **Diagnóstico:** KPI 1 y 2, y el reingreso por complejidad × fallas, familia y centro, con la holgura por mes.
   - **Comparación de reglas:** segmentador de `DimRegla`, más candidatos, atendibles, fuera de capacidad, minutos, costo y KPI 3 a 6.
   - Segmentadores comunes: `DimFecha[Periodo]`, `DimCentro[Centro]`, `DimFamilia[Familia]`.
