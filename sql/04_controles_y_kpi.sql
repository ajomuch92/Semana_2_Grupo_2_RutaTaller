/* =====================================================================
   RutaTaller DW - 04 Controles de carga y verificación de KPI
   Correr por partes en SSMS y capturar pantallas como evidencia.
   ===================================================================== */
USE ajomuch92_ruta_taller;
GO

/* 1. Bitácora de controles (todas las filas deben decir OK o INFO) */
SELECT Paso, Detalle, Valor, Esperado, Resultado FROM etl.Control ORDER BY ControlID;

/* 2. Conciliación de conteos origen -> DW */
SELECT 'stg.Eventos (con duplicados)' AS Tabla, COUNT(*) AS Filas FROM stg.Eventos
UNION ALL SELECT 'stg.Eventos distintos',   COUNT(*) FROM (SELECT DISTINCT * FROM stg.Eventos) x
UNION ALL SELECT 'dw.FactEvento',           COUNT(*) FROM dw.FactEvento
UNION ALL SELECT 'stg.Capacidad',           COUNT(*) FROM stg.Capacidad
UNION ALL SELECT 'dw.FactCapacidad',        COUNT(*) FROM dw.FactCapacidad
UNION ALL SELECT 'dw.DimCentro',            COUNT(*) FROM dw.DimCentro
UNION ALL SELECT 'dw.DimFamilia',           COUNT(*) FROM dw.DimFamilia
UNION ALL SELECT 'dw.DimFecha',             COUNT(*) FROM dw.DimFecha;

/* 3. Eventos por mes y centro (todos los centros y días tienen capacidad) */
SELECT d.Mes, c.Centro_ID, COUNT(*) AS Eventos,
       SUM(CASE WHEN k.FechaKey IS NULL THEN 1 ELSE 0 END) AS Sin_capacidad
FROM dw.FactEvento e
JOIN dw.DimFecha d  ON d.FechaKey = e.FechaKey
JOIN dw.DimCentro c ON c.CentroKey = e.CentroKey
LEFT JOIN dw.FactCapacidad k ON k.FechaKey = e.FechaKey AND k.CentroKey = e.CentroKey
GROUP BY d.Mes, c.Centro_ID ORDER BY d.Mes, c.Centro_ID;

/* 4. Capacidad no duplicada: la suma correcta va en su propio grano */
SELECT d.Mes,
       (SELECT SUM(k2.Minutos_disponibles) FROM dw.FactCapacidad k2
          JOIN dw.DimFecha d2 ON d2.FechaKey = k2.FechaKey WHERE d2.Mes = d.Mes) AS Minutos_correctos,
       SUM(k.Minutos_disponibles) AS Minutos_si_se_une_con_eventos   -- se infla ~13 veces
FROM dw.FactEvento e
JOIN dw.DimFecha d ON d.FechaKey = e.FechaKey
JOIN dw.FactCapacidad k ON k.FechaKey = e.FechaKey AND k.CentroKey = e.CentroKey
GROUP BY d.Mes ORDER BY d.Mes;

/* 5. Línea base de los 6 KPI (julio y agosto, regla A con capacidad 100 %) */
SELECT
  CAST(AVG(CAST(e.Reingreso_30d AS DECIMAL(6,4))) AS DECIMAL(6,4))   AS KPI1_Tasa_reingreso,
  CAST(SUM(e.Costo_retrabajo_L) / NULLIF(COUNT(*),0) AS DECIMAL(10,2)) AS KPI2_Costo_retrabajo_por_orden
FROM dw.FactEvento e JOIN dw.DimFecha d ON d.FechaKey = e.FechaKey
WHERE d.Mes IN (7,8);

SELECT Regla, Escenario, Periodo,
       Cobertura_reingresos         AS KPI3_Cobertura,
       Precision_revision           AS KPI4_Precision,
       Pct_pierden_holgura          AS KPI5_Pct_pierden_holgura,
       Costo_por_reingreso_cubierto AS KPI6_Costo_por_reingreso_cubierto
FROM dw.vResumenRegla ORDER BY Periodo, Regla, Escenario;

/* 6. Comparación completa de reglas (tabla del informe ejecutivo) */
SELECT * FROM dw.vResumenRegla WHERE Periodo = N'Prueba (sep-oct)' ORDER BY Escenario, Regla;

/* 7. VERIFICACIÓN 1 - KPI1 con filtros: sep-oct, centro C02, familia F05
      Comparar contra la tarjeta de Power BI con los mismos segmentadores. */
SELECT COUNT(*) AS Ordenes, SUM(CAST(e.Reingreso_30d AS INT)) AS Reingresos,
       CAST(1.0 * SUM(CAST(e.Reingreso_30d AS INT)) / NULLIF(COUNT(*),0) AS DECIMAL(6,4)) AS Tasa_reingreso
FROM dw.FactEvento e
JOIN dw.DimFecha d   ON d.FechaKey = e.FechaKey
JOIN dw.DimCentro c  ON c.CentroKey = e.CentroKey
JOIN dw.DimFamilia f ON f.FamiliaKey = e.FamiliaKey
WHERE d.Mes IN (9,10) AND c.Centro_ID = 'C02' AND f.Familia_ID = 'F05';

/* 8. VERIFICACIÓN 2 - KPI3 Cobertura de la regla A (100 %) en sep-oct, centro C02.
      Ojo: el denominador son TODOS los reingresos del filtro, no solo los candidatos. */
SELECT
  SUM(CASE WHEN x.Atendible = 1 THEN CAST(e.Reingreso_30d AS INT) ELSE 0 END) AS Reingresos_cubiertos,
  (SELECT SUM(CAST(e2.Reingreso_30d AS INT)) FROM dw.FactEvento e2
     JOIN dw.DimFecha d2 ON d2.FechaKey = e2.FechaKey
     JOIN dw.DimCentro c2 ON c2.CentroKey = e2.CentroKey
    WHERE d2.Mes IN (9,10) AND c2.Centro_ID = 'C02') AS Reingresos_totales
FROM dw.ResultadoRegla x
JOIN dw.FactEvento e ON e.Evento_ID = x.Evento_ID
JOIN dw.DimFecha d   ON d.FechaKey = e.FechaKey
JOIN dw.DimCentro c  ON c.CentroKey = e.CentroKey
WHERE x.ReglaKey = 1 AND d.Mes IN (9,10) AND c.Centro_ID = 'C02';
