/* =====================================================================
   RutaTaller DW - 01 Crear esquemas y tablas
   La base ajomuch92_ruta_taller ya existe; todo vive en ella, separado por esquemas.
   Es re-ejecutable: borra y recrea las tablas.
   Capas:
     stg  -> datos crudos tal como vienen en los archivos (todo texto)
     dw   -> modelo estrella limpio (dimensiones + hechos)
     etl  -> bitácora de controles de carga
   ===================================================================== */
USE ajomuch92_ruta_taller;
GO
IF SCHEMA_ID('stg') IS NULL EXEC('CREATE SCHEMA stg');
IF SCHEMA_ID('dw')  IS NULL EXEC('CREATE SCHEMA dw');
IF SCHEMA_ID('etl') IS NULL EXEC('CREATE SCHEMA etl');
GO

-- Orden de borrado: primero tablas que referencian
DROP TABLE IF EXISTS dw.ResultadoRegla;
DROP TABLE IF EXISTS dw.FactEvento;
DROP TABLE IF EXISTS dw.FactCapacidad;
DROP TABLE IF EXISTS dw.DimRegla;
DROP TABLE IF EXISTS dw.DimFecha;
DROP TABLE IF EXISTS dw.DimCentro;
DROP TABLE IF EXISTS dw.DimFamilia;
DROP TABLE IF EXISTS stg.Eventos;
DROP TABLE IF EXISTS stg.Centros;
DROP TABLE IF EXISTS stg.Familias;
DROP TABLE IF EXISTS stg.Calendario;
DROP TABLE IF EXISTS stg.Capacidad;
DROP TABLE IF EXISTS etl.Control;
GO

/* ---------------------------- STAGING ------------------------------ */
-- Todo como texto: la conversión de tipos se hace y documenta en 02.
CREATE TABLE stg.Eventos (
    Evento_ID           NVARCHAR(50),
    Fecha               NVARCHAR(50),
    Centro_ID           NVARCHAR(50),
    Familia_ID          NVARCHAR(50),
    Complejidad         NVARCHAR(50),
    Horas_comprometidas NVARCHAR(50),
    Horas_transcurridas NVARCHAR(50),
    Fallas_prueba       NVARCHAR(50),
    Piezas_sustituidas  NVARCHAR(50),
    Reingreso_30d       NVARCHAR(50),
    Costo_retrabajo_L   NVARCHAR(50)
);
CREATE TABLE stg.Centros    (Centro_ID NVARCHAR(50), Centro NVARCHAR(100));
CREATE TABLE stg.Familias   (Familia_ID NVARCHAR(50), Nombre NVARCHAR(100));
CREATE TABLE stg.Calendario (Fecha NVARCHAR(50), Mes NVARCHAR(50), Dia_semana NVARCHAR(50));
CREATE TABLE stg.Capacidad (
    Fecha               NVARCHAR(50),
    Centro_ID           NVARCHAR(50),
    Minutos_disponibles NVARCHAR(50),
    Minutos_evento      NVARCHAR(50),
    Tarifa_hora_L       NVARCHAR(50)
);
GO

/* ---------------------------- DIMENSIONES -------------------------- */
CREATE TABLE dw.DimFecha (
    FechaKey    INT         NOT NULL PRIMARY KEY,   -- yyyymmdd
    Fecha       DATE        NOT NULL UNIQUE,
    Anio        SMALLINT    NOT NULL,
    Mes         TINYINT     NOT NULL CHECK (Mes BETWEEN 1 AND 12),
    NombreMes   NVARCHAR(15) NOT NULL,
    Dia_semana  TINYINT     NOT NULL CHECK (Dia_semana BETWEEN 1 AND 7),  -- ISO 1=lunes
    NombreDia   NVARCHAR(15) NOT NULL,
    Periodo     NVARCHAR(30) NOT NULL   -- 'Diseño (jul-ago)' / 'Prueba (sep-oct)'
);
CREATE TABLE dw.DimCentro (
    CentroKey   INT IDENTITY(1,1) PRIMARY KEY,
    Centro_ID   CHAR(3)       NOT NULL UNIQUE,
    Centro      NVARCHAR(100) NOT NULL
);
CREATE TABLE dw.DimFamilia (
    FamiliaKey  INT IDENTITY(1,1) PRIMARY KEY,
    Familia_ID  CHAR(3)       NOT NULL UNIQUE,
    Familia     NVARCHAR(100) NOT NULL
);
-- Dimensión de reglas/escenarios para comparar en Power BI
CREATE TABLE dw.DimRegla (
    ReglaKey        INT          NOT NULL PRIMARY KEY,
    Regla           NVARCHAR(40) NOT NULL,
    Escenario       NVARCHAR(40) NOT NULL,
    FactorCapacidad DECIMAL(4,2) NOT NULL,
    Descripcion     NVARCHAR(400) NOT NULL
);
GO

/* ---------------------------- HECHOS ------------------------------- */
-- Grano: un centro por día. Se agrega aparte de los eventos para no duplicar.
CREATE TABLE dw.FactCapacidad (
    FechaKey            INT NOT NULL REFERENCES dw.DimFecha(FechaKey),
    CentroKey           INT NOT NULL REFERENCES dw.DimCentro(CentroKey),
    Minutos_disponibles INT NOT NULL CHECK (Minutos_disponibles >= 0),
    Minutos_evento      INT NOT NULL CHECK (Minutos_evento > 0),
    Tarifa_hora_L       DECIMAL(10,2) NOT NULL CHECK (Tarifa_hora_L > 0),
    Cupos_revision      AS (Minutos_disponibles / Minutos_evento) PERSISTED,  -- derivado: división entera
    CONSTRAINT PK_FactCapacidad PRIMARY KEY (FechaKey, CentroKey)
);
-- Grano: una orden lista para cerrar (evento único).
CREATE TABLE dw.FactEvento (
    Evento_ID            VARCHAR(20)  NOT NULL PRIMARY KEY,
    FechaKey             INT NOT NULL REFERENCES dw.DimFecha(FechaKey),
    CentroKey            INT NOT NULL REFERENCES dw.DimCentro(CentroKey),
    FamiliaKey           INT NOT NULL REFERENCES dw.DimFamilia(FamiliaKey),
    -- Variables conocidas al momento de decidir
    Complejidad          TINYINT      NOT NULL CHECK (Complejidad BETWEEN 1 AND 5),
    Horas_comprometidas  DECIMAL(6,1) NOT NULL CHECK (Horas_comprometidas > 0),
    Horas_transcurridas  DECIMAL(6,1) NOT NULL CHECK (Horas_transcurridas >= 0),
    Fallas_prueba        TINYINT      NOT NULL CHECK (Fallas_prueba >= 0),
    Piezas_sustituidas   TINYINT      NOT NULL CHECK (Piezas_sustituidas >= 0),
    -- Resultados posteriores: SOLO para evaluar, nunca dentro de las reglas
    Reingreso_30d        TINYINT      NOT NULL CHECK (Reingreso_30d IN (0,1)),  -- TINYINT y no BIT: Power BI suma 0/1
    Costo_retrabajo_L    DECIMAL(10,2) NOT NULL CHECK (Costo_retrabajo_L >= 0),
    -- Campos derivados
    Holgura_h            DECIMAL(7,2) NOT NULL,  -- comprometidas - transcurridas
    Holgura_post_rev_h   DECIMAL(7,2) NOT NULL,  -- holgura - Minutos_evento/60 del centro y día
    Pierde_holgura       TINYINT      NOT NULL,  -- 1 si tenía holgura >= 0 y la revisión la vuelve negativa
    Puntaje_riesgo       TINYINT      NOT NULL,  -- ver 02: 2*(fallas>=2) + 1*(fallas=1) + 2*(complejidad>=4)
    Minutos_evento       SMALLINT     NOT NULL,  -- minutos que tomaría su revisión (centro y día)
    Costo_revision_L     DECIMAL(10,2) NOT NULL  -- Minutos_evento / 60 * Tarifa_hora_L
);
GO

/* ---------------------- RESULTADO DE LA SIMULACIÓN ------------------ */
-- Una fila por (regla/escenario, evento candidato). Atendible = cabe en la capacidad.
CREATE TABLE dw.ResultadoRegla (
    ReglaKey    INT         NOT NULL REFERENCES dw.DimRegla(ReglaKey),
    Evento_ID   VARCHAR(20) NOT NULL REFERENCES dw.FactEvento(Evento_ID),
    Prioridad   INT         NOT NULL,   -- posición dentro de su centro y día
    Atendible   TINYINT     NOT NULL CHECK (Atendible IN (0,1)),
    CONSTRAINT PK_ResultadoRegla PRIMARY KEY (ReglaKey, Evento_ID)
);
GO

/* ---------------------------- CONTROL ------------------------------ */
CREATE TABLE etl.Control (
    ControlID   INT IDENTITY(1,1) PRIMARY KEY,
    FechaHora   DATETIME2     NOT NULL DEFAULT SYSDATETIME(),
    Paso        NVARCHAR(100) NOT NULL,
    Detalle     NVARCHAR(200) NOT NULL,
    Valor       DECIMAL(18,2) NULL,
    Esperado    DECIMAL(18,2) NULL,
    Resultado   AS (CASE WHEN Esperado IS NULL THEN 'INFO'
                         WHEN Valor = Esperado THEN 'OK' ELSE 'REVISAR' END)
);
GO
