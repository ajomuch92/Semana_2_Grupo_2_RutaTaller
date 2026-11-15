/* =====================================================================
   RutaTaller DW - 02 Transformación stg -> dw
   Crea el procedimiento etl.usp_transformar. El script de Python lo
   ejecuta al terminar la carga de staging (también puede correrse a mano:
   EXEC etl.usp_transformar;).

   Transformaciones documentadas
   T1 Limpieza de claves ...... TRIM + UPPER en Centro_ID y Familia_ID (' c03 ' -> 'C03')
   T2 Limpieza de fechas ...... dos formatos: 'yyyy-mm-dd' (estilo 23) y 'dd/mm/yyyy' (estilo 103)
   T3 Conversión de tipos ..... texto -> TINYINT / DECIMAL / BIT / DATE con TRY_CONVERT
   T4 Deduplicación ........... DISTINCT sobre la fila completa (10,010 -> 10,000) y Evento_ID único
   T5 Control de rangos ....... complejidad 1-5, horas >= 0, conteos >= 0, reingreso 0/1,
                                costo >= 0 y costo = 0 cuando no hubo reingreso
   T6 Validación de relaciones  cada evento debe tener centro, familia, fecha y capacidad del centro-día
   T7 Campos derivados ........ Holgura_h, Holgura_post_rev_h, Pierde_holgura, Puntaje_riesgo,
                                Minutos_evento, Costo_revision_L, FechaKey, Periodo, Cupos_revision
   ===================================================================== */
USE ajomuch92_ruta_taller;
GO
CREATE OR ALTER PROCEDURE etl.usp_transformar
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    BEGIN TRAN;

    DELETE FROM dw.ResultadoRegla;
    DELETE FROM dw.FactEvento;
    DELETE FROM dw.FactCapacidad;
    DELETE FROM dw.DimFecha;
    DELETE FROM dw.DimCentro;
    DELETE FROM dw.DimFamilia;
    DELETE FROM etl.Control;

    /* ---------- Conteos de origen (staging) ---------- */
    INSERT etl.Control (Paso, Detalle, Valor, Esperado)
    SELECT '0 Staging', 'Filas en stg.Eventos', COUNT(*), 10010 FROM stg.Eventos UNION ALL
    SELECT '0 Staging', 'Filas en stg.Centros', COUNT(*), 6     FROM stg.Centros UNION ALL
    SELECT '0 Staging', 'Filas en stg.Familias', COUNT(*), 8    FROM stg.Familias UNION ALL
    SELECT '0 Staging', 'Filas en stg.Calendario', COUNT(*), 123 FROM stg.Calendario UNION ALL
    SELECT '0 Staging', 'Filas en stg.Capacidad', COUNT(*), 738 FROM stg.Capacidad;

    /* ---------- Dimensiones ---------- */
    -- T2/T3 en calendario
    INSERT dw.DimFecha (FechaKey, Fecha, Anio, Mes, NombreMes, Dia_semana, NombreDia, Periodo)
    SELECT CONVERT(INT, FORMAT(f.Fecha, 'yyyyMMdd')),
           f.Fecha, YEAR(f.Fecha), CAST(c.Mes AS TINYINT),
           CHOOSE(CAST(c.Mes AS INT), 'Enero','Febrero','Marzo','Abril','Mayo','Junio','Julio',
                  'Agosto','Septiembre','Octubre','Noviembre','Diciembre'),
           CAST(c.Dia_semana AS TINYINT),
           CHOOSE(CAST(c.Dia_semana AS INT), 'Lunes','Martes','Miércoles','Jueves','Viernes','Sábado','Domingo'),
           CASE WHEN CAST(c.Mes AS INT) IN (7,8) THEN N'Diseño (jul-ago)'
                WHEN CAST(c.Mes AS INT) IN (9,10) THEN N'Prueba (sep-oct)'
                ELSE N'Fuera de estudio' END
    FROM stg.Calendario c
    CROSS APPLY (SELECT COALESCE(TRY_CONVERT(DATE, LTRIM(RTRIM(c.Fecha)), 23),
                                 TRY_CONVERT(DATE, LTRIM(RTRIM(c.Fecha)), 103)) AS Fecha) f;

    -- T1 en catálogos
    INSERT dw.DimCentro (Centro_ID, Centro)
    SELECT DISTINCT UPPER(LTRIM(RTRIM(Centro_ID))), LTRIM(RTRIM(Centro)) FROM stg.Centros;

    INSERT dw.DimFamilia (Familia_ID, Familia)
    SELECT DISTINCT UPPER(LTRIM(RTRIM(Familia_ID))), LTRIM(RTRIM(Nombre)) FROM stg.Familias;

    /* ---------- Hecho capacidad (T1, T2, T3, T6) ---------- */
    INSERT dw.FactCapacidad (FechaKey, CentroKey, Minutos_disponibles, Minutos_evento, Tarifa_hora_L)
    SELECT d.FechaKey, c.CentroKey,
           TRY_CONVERT(INT, s.Minutos_disponibles),
           TRY_CONVERT(INT, s.Minutos_evento),
           TRY_CONVERT(DECIMAL(10,2), s.Tarifa_hora_L)
    FROM stg.Capacidad s
    JOIN dw.DimFecha  d ON d.Fecha = COALESCE(TRY_CONVERT(DATE, LTRIM(RTRIM(s.Fecha)), 23),
                                              TRY_CONVERT(DATE, LTRIM(RTRIM(s.Fecha)), 103))
    JOIN dw.DimCentro c ON c.Centro_ID = UPPER(LTRIM(RTRIM(s.Centro_ID)));

    INSERT etl.Control (Paso, Detalle, Valor, Esperado)
    SELECT 'T6 Relaciones', 'Filas de capacidad cargadas (centro x día)', COUNT(*), 738 FROM dw.FactCapacidad;

    /* ---------- Eventos: T4 deduplicación ---------- */
    SELECT DISTINCT * INTO #dedup FROM stg.Eventos;

    INSERT etl.Control (Paso, Detalle, Valor, Esperado)
    SELECT 'T4 Deduplicación', 'Copias exactas eliminadas',
           (SELECT COUNT(*) FROM stg.Eventos) - COUNT(*), 10 FROM #dedup;

    /* ---------- T1, T2, T3: limpieza y tipos ---------- */
    SELECT LTRIM(RTRIM(Evento_ID)) AS Evento_ID,
           COALESCE(TRY_CONVERT(DATE, LTRIM(RTRIM(Fecha)), 23),
                    TRY_CONVERT(DATE, LTRIM(RTRIM(Fecha)), 103))      AS Fecha,
           UPPER(LTRIM(RTRIM(Centro_ID)))                              AS Centro_ID,
           UPPER(LTRIM(RTRIM(Familia_ID)))                             AS Familia_ID,
           TRY_CONVERT(INT, Complejidad)                               AS Complejidad,
           TRY_CONVERT(DECIMAL(6,1), Horas_comprometidas)              AS Horas_comprometidas,
           TRY_CONVERT(DECIMAL(6,1), Horas_transcurridas)              AS Horas_transcurridas,
           TRY_CONVERT(INT, Fallas_prueba)                             AS Fallas_prueba,
           TRY_CONVERT(INT, Piezas_sustituidas)                        AS Piezas_sustituidas,
           TRY_CONVERT(INT, Reingreso_30d)                             AS Reingreso_30d,
           TRY_CONVERT(DECIMAL(10,2), Costo_retrabajo_L)               AS Costo_retrabajo_L
    INTO #ev
    FROM #dedup;

    INSERT etl.Control (Paso, Detalle, Valor, Esperado)
    SELECT 'T2 Fechas', 'Fechas en formato dd/mm/yyyy convertidas',
           SUM(CASE WHEN Fecha LIKE '%/%' THEN 1 ELSE 0 END), NULL FROM #dedup UNION ALL
    SELECT 'T2 Fechas', 'Fechas sin poder convertir', SUM(CASE WHEN Fecha IS NULL THEN 1 ELSE 0 END), 0 FROM #ev UNION ALL
    SELECT 'T1 Claves', 'Claves de centro con espacios o minúsculas corregidas',
           SUM(CASE WHEN Centro_ID COLLATE Latin1_General_CS_AS <> UPPER(LTRIM(RTRIM(Centro_ID))) THEN 1 ELSE 0 END),
           NULL FROM #dedup UNION ALL
    SELECT 'T3 Tipos', 'Valores numéricos sin poder convertir',
           SUM(CASE WHEN Complejidad IS NULL OR Horas_comprometidas IS NULL OR Horas_transcurridas IS NULL
                      OR Fallas_prueba IS NULL OR Piezas_sustituidas IS NULL OR Reingreso_30d IS NULL
                      OR Costo_retrabajo_L IS NULL THEN 1 ELSE 0 END), 0 FROM #ev UNION ALL
    SELECT 'T4 Deduplicación', 'Evento_ID repetidos después de DISTINCT',
           COUNT(*) - COUNT(DISTINCT Evento_ID), 0 FROM #ev;

    /* ---------- T5 control de rangos ---------- */
    -- Un NULL (no convertible) también cuenta como fuera de rango.
    SELECT e.*,
           CASE WHEN e.Complejidad BETWEEN 1 AND 5
                 AND e.Horas_comprometidas > 0 AND e.Horas_transcurridas >= 0
                 AND e.Fallas_prueba >= 0 AND e.Piezas_sustituidas >= 0
                 AND e.Reingreso_30d IN (0,1) AND e.Costo_retrabajo_L >= 0
                 AND NOT (e.Reingreso_30d = 0 AND e.Costo_retrabajo_L <> 0)
                 AND e.Fecha BETWEEN '2026-07-01' AND '2026-10-31'
                THEN 0 ELSE 1 END AS Fuera_rango
    INTO #evr
    FROM #ev e;

    INSERT etl.Control (Paso, Detalle, Valor, Esperado)
    SELECT 'T5 Rangos', 'Eventos fuera de rango (excluidos)', SUM(Fuera_rango), 0 FROM #evr;

    /* ---------- T6 relaciones + T7 derivados -> FactEvento ---------- */
    INSERT dw.FactEvento (Evento_ID, FechaKey, CentroKey, FamiliaKey, Complejidad,
                          Horas_comprometidas, Horas_transcurridas, Fallas_prueba, Piezas_sustituidas,
                          Reingreso_30d, Costo_retrabajo_L,
                          Holgura_h, Holgura_post_rev_h, Pierde_holgura, Puntaje_riesgo,
                          Minutos_evento, Costo_revision_L)
    SELECT e.Evento_ID, d.FechaKey, c.CentroKey, f.FamiliaKey, e.Complejidad,
           e.Horas_comprometidas, e.Horas_transcurridas, e.Fallas_prueba, e.Piezas_sustituidas,
           e.Reingreso_30d, e.Costo_retrabajo_L,
           h.Holgura, h.Holgura_post,
           CASE WHEN h.Holgura >= 0 AND h.Holgura_post < 0 THEN 1 ELSE 0 END,
           2 * CASE WHEN e.Fallas_prueba >= 2 THEN 1 ELSE 0 END
         + 1 * CASE WHEN e.Fallas_prueba = 1  THEN 1 ELSE 0 END
         + 2 * CASE WHEN e.Complejidad  >= 4  THEN 1 ELSE 0 END,
           k.Minutos_evento,
           CAST(k.Minutos_evento / 60.0 * k.Tarifa_hora_L AS DECIMAL(10,2))
    FROM #evr e
    JOIN dw.DimFecha      d  ON d.Fecha = e.Fecha
    JOIN dw.DimCentro     c  ON c.Centro_ID = e.Centro_ID
    JOIN dw.DimFamilia    f  ON f.Familia_ID = e.Familia_ID
    JOIN dw.FactCapacidad k  ON k.FechaKey = d.FechaKey AND k.CentroKey = c.CentroKey
    CROSS APPLY (SELECT CAST(e.Horas_comprometidas - e.Horas_transcurridas AS DECIMAL(7,2)) AS Holgura,
                        CAST(e.Horas_comprometidas - e.Horas_transcurridas
                             - k.Minutos_evento / 60.0 AS DECIMAL(7,2)) AS Holgura_post) h
    WHERE e.Fuera_rango = 0;

    INSERT etl.Control (Paso, Detalle, Valor, Esperado)
    SELECT 'T6 Relaciones', 'Eventos sin centro, familia, fecha o capacidad (huérfanos)',
           (SELECT COUNT(*) FROM #evr WHERE Fuera_rango = 0) - COUNT(*), 0 FROM dw.FactEvento UNION ALL
    SELECT 'T7 Derivados', 'Eventos cargados en dw.FactEvento', COUNT(*), 10000 FROM dw.FactEvento UNION ALL
    SELECT 'T7 Derivados', 'Eventos con holgura negativa antes de revisar',
           SUM(CASE WHEN Holgura_h < 0 THEN 1 ELSE 0 END), NULL FROM dw.FactEvento UNION ALL
    SELECT 'T7 Derivados', 'Eventos que perderían holgura si TODOS se revisaran',
           SUM(CAST(Pierde_holgura AS INT)), NULL FROM dw.FactEvento;

    /* ---------- Capacidad no duplicada al agregar eventos ---------- */
    -- Correcto: sumar la capacidad en su propio grano. Incorrecto: sumarla tras un JOIN con eventos.
    INSERT etl.Control (Paso, Detalle, Valor, Esperado)
    SELECT 'Capacidad', 'Minutos disponibles en el origen (stg)',
           SUM(TRY_CONVERT(INT, Minutos_disponibles)), NULL FROM stg.Capacidad UNION ALL
    SELECT 'Capacidad', 'Minutos disponibles en dw.FactCapacidad',
           SUM(Minutos_disponibles), (SELECT SUM(TRY_CONVERT(INT, Minutos_disponibles)) FROM stg.Capacidad)
    FROM dw.FactCapacidad UNION ALL
    SELECT 'Capacidad', 'Minutos sumados MAL (JOIN evento-capacidad, se duplica)',
           SUM(k.Minutos_disponibles), NULL
    FROM dw.FactEvento e JOIN dw.FactCapacidad k ON k.FechaKey = e.FechaKey AND k.CentroKey = e.CentroKey;

    COMMIT;

    SELECT Paso, Detalle, Valor, Esperado, Resultado FROM etl.Control ORDER BY ControlID;
END;
GO
