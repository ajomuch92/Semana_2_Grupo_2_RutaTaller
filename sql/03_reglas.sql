/* =====================================================================
   RutaTaller DW - 03 Reglas de priorización y simulación
   Ejecutar después de la carga (el script de Python lo invoca:
   EXEC dw.usp_simular_reglas;).

   Variables permitidas en las reglas (conocidas al decidir):
     Complejidad, Fallas_prueba, Piezas_sustituidas, Horas_*, Holgura, Familia, Centro
   Prohibidas en las reglas (resultado posterior, solo para evaluar):
     Reingreso_30d, Costo_retrabajo_L

   Puntaje_riesgo = 2*(Fallas_prueba >= 2) + 1*(Fallas_prueba = 1) + 2*(Complejidad >= 4)
     Jul-ago: reingreso 3-8 % con complejidad <= 3 y 0-1 fallas,
              15-19 % con complejidad >= 4, 20-31 % con 2+ fallas.
     Piezas_sustituidas, familia y centro casi no discriminan (10-14 %).

   REGLA A · Riesgo técnico
     Reúne : Fallas_prueba >= 2  O  Complejidad >= 4
     Ordena: Puntaje_riesgo DESC
   REGLA B · Riesgo con holgura
     Reúne : lo mismo que A  Y  Holgura_post_rev_h >= 0
             (la revisión cabe sin incumplir el plazo prometido)
     Ordena: Puntaje_riesgo DESC
   Desempate (ambas): Fallas_prueba DESC, Complejidad DESC, Evento_ID ASC
   Capacidad: dentro de cada centro y día se atienden las primeras
     FLOOR(Minutos_disponibles * factor / Minutos_evento) órdenes.
     factor = 1.00 (capacidad real) o 0.80 (20 % menos).
   Costo laboral = atendibles * Minutos_evento / 60 * Tarifa_hora_L
   ===================================================================== */
USE ajomuch92_ruta_taller;
GO
DELETE FROM dw.ResultadoRegla;
DELETE FROM dw.DimRegla;
INSERT dw.DimRegla (ReglaKey, Regla, Escenario, FactorCapacidad, Descripcion) VALUES
 (1, N'A · Riesgo técnico',     N'Capacidad 100 %', 1.00, N'Fallas>=2 o Complejidad>=4; orden por puntaje de riesgo'),
 (2, N'A · Riesgo técnico',     N'Capacidad 80 %',  0.80, N'Igual que A con 20 % menos minutos'),
 (3, N'B · Riesgo con holgura', N'Capacidad 100 %', 1.00, N'Candidatos de A con holgura tras revisión >= 0; orden por puntaje'),
 (4, N'B · Riesgo con holgura', N'Capacidad 80 %',  0.80, N'Igual que B con 20 % menos minutos');
GO

CREATE OR ALTER PROCEDURE dw.usp_simular_reglas
AS
BEGIN
    SET NOCOUNT ON;
    DELETE FROM dw.ResultadoRegla;

    WITH cand AS (
        SELECT r.ReglaKey, r.FactorCapacidad, e.Evento_ID, e.FechaKey, e.CentroKey,
               ROW_NUMBER() OVER (
                   PARTITION BY r.ReglaKey, e.FechaKey, e.CentroKey
                   ORDER BY e.Puntaje_riesgo DESC, e.Fallas_prueba DESC,
                            e.Complejidad DESC, e.Evento_ID ASC) AS Prioridad
        FROM dw.FactEvento e
        CROSS JOIN dw.DimRegla r
        WHERE (e.Fallas_prueba >= 2 OR e.Complejidad >= 4)
          AND (r.Regla LIKE N'A%' OR e.Holgura_post_rev_h >= 0)
    )
    INSERT dw.ResultadoRegla (ReglaKey, Evento_ID, Prioridad, Atendible)
    SELECT c.ReglaKey, c.Evento_ID, c.Prioridad,
           CASE WHEN c.Prioridad <= FLOOR(k.Minutos_disponibles * c.FactorCapacidad / k.Minutos_evento)
                THEN 1 ELSE 0 END
    FROM cand c
    JOIN dw.FactCapacidad k ON k.FechaKey = c.FechaKey AND k.CentroKey = c.CentroKey;
END;
GO

/* Resumen por regla y período (lo que se compara en el informe y en Power BI) */
CREATE OR ALTER VIEW dw.vResumenRegla AS
WITH base AS (   -- total del problema histórico por período (denominador de cobertura)
    SELECT d.Periodo,
           COUNT(*)                                   AS Ordenes,
           SUM(CAST(e.Reingreso_30d AS INT))          AS Reingresos,
           SUM(e.Costo_retrabajo_L)                   AS Costo_retrabajo
    FROM dw.FactEvento e JOIN dw.DimFecha d ON d.FechaKey = e.FechaKey
    GROUP BY d.Periodo
),
cap AS (         -- capacidad en su propio grano (no se duplica)
    SELECT d.Periodo, SUM(k.Minutos_disponibles) AS Minutos_disponibles
    FROM dw.FactCapacidad k JOIN dw.DimFecha d ON d.FechaKey = k.FechaKey
    GROUP BY d.Periodo
),
res AS (
    SELECT r.ReglaKey, d.Periodo,
           COUNT(*)                                                         AS Candidatos,
           SUM(CAST(x.Atendible AS INT))                                    AS Atendibles,
           SUM(e.Minutos_evento)                                            AS Minutos_requeridos,
           SUM(CASE WHEN x.Atendible = 1 THEN e.Minutos_evento ELSE 0 END)  AS Minutos_usados,
           SUM(CASE WHEN x.Atendible = 1 THEN e.Costo_revision_L ELSE 0 END) AS Costo_laboral_L,
           SUM(CASE WHEN x.Atendible = 1 THEN CAST(e.Reingreso_30d AS INT) ELSE 0 END) AS Reingresos_cubiertos,
           SUM(CASE WHEN x.Atendible = 1 THEN e.Costo_retrabajo_L ELSE 0 END)          AS Costo_retrabajo_cubierto,
           SUM(CASE WHEN x.Atendible = 1 THEN CAST(e.Pierde_holgura AS INT) ELSE 0 END) AS Pierden_holgura,
           SUM(CASE WHEN x.Atendible = 1 AND e.Holgura_h < 0 THEN 1 ELSE 0 END)         AS Atendidas_ya_vencidas
    FROM dw.ResultadoRegla x
    JOIN dw.DimRegla      r ON r.ReglaKey = x.ReglaKey
    JOIN dw.FactEvento    e ON e.Evento_ID = x.Evento_ID
    JOIN dw.DimFecha      d ON d.FechaKey = e.FechaKey
    GROUP BY r.ReglaKey, d.Periodo
)
SELECT r.Regla, r.Escenario, res.Periodo,
       res.Candidatos, res.Atendibles, res.Candidatos - res.Atendibles AS Fuera_capacidad,
       res.Minutos_requeridos, res.Minutos_usados,
       CAST(cap.Minutos_disponibles * r.FactorCapacidad AS INT)        AS Minutos_disponibles,
       CAST(res.Costo_laboral_L AS DECIMAL(12,2))                      AS Costo_laboral_L,
       res.Reingresos_cubiertos, base.Reingresos AS Reingresos_totales,
       CAST(1.0 * res.Reingresos_cubiertos / NULLIF(base.Reingresos, 0) AS DECIMAL(6,4))   AS Cobertura_reingresos,
       CAST(res.Costo_retrabajo_cubierto / NULLIF(base.Costo_retrabajo, 0) AS DECIMAL(6,4)) AS Cobertura_costo,
       CAST(1.0 * res.Reingresos_cubiertos / NULLIF(res.Atendibles, 0) AS DECIMAL(6,4))     AS Precision_revision,
       CAST(res.Costo_laboral_L / NULLIF(res.Reingresos_cubiertos, 0) AS DECIMAL(10,2))     AS Costo_por_reingreso_cubierto,
       res.Pierden_holgura,
       CAST(1.0 * res.Pierden_holgura / NULLIF(res.Atendibles, 0) AS DECIMAL(6,4))          AS Pct_pierden_holgura,
       res.Atendidas_ya_vencidas
FROM res
JOIN dw.DimRegla r ON r.ReglaKey = res.ReglaKey
JOIN base ON base.Periodo = res.Periodo
JOIN cap  ON cap.Periodo  = res.Periodo;
GO
