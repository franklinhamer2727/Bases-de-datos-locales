/* =====================================================================================
   PROCEDIMIENTO : dbo.SP_BDS_SALDOS_OPERATIVOS_PRE_PROMEDIO_H6        (versión 4)
   MOTOR         : SQL Server 2016 SP1+
   DESTINO       : dbo.BDS_SALDOS_OPERATIVOS_PRE_PROMEDIO_LIMPIO

   RESULTADO (igual al SP original)
   -------------------------------------------------------------------------------------
   Cada llave (ID_OPERACION_CIERRE, COD_RUBRO) que aparece al menos una vez en el mes
   tiene UNA fila por día, del día 1 a @FECHA_PROCESO:
     - Día hábil con registro     -> saldo del día                    (ORIGINAL)
     - Fin de semana / feriado    -> copia del último día hábil       (COPIA_HABIL)
                                     (IND_DIA_HABIL = 'N' en BDS_CALENDARIOS, COD_CALENDARIO = 1;
                                      si el día 1 es feriado, copia el último hábil del mes anterior)
     - Día hábil SIN registro     -> montos en 0, atributos de su fila de ayer
     - Antes de su 1.ª aparición  -> montos en 0, atributos de su primer registro
   La llave es BDS_SALDOS_CIERRE.ID_OPERACION (sin CONCAT).

   CÓMO FUNCIONA (un solo recorrido, día por día)
   -------------------------------------------------------------------------------------
   Para cada día D del mes:
     A. DELETE del día D en el destino, en lotes.
     B. #DIA <- filas deduplicadas del día de origen de D. En fines de semana y feriados se
        reutiliza #DIA, sin volver a leer la fuente.
     C. Destino[D] <- #DIA                                    (ORIGINAL / COPIA_HABIL)
     D. Destino[D] <- llaves de Destino[D-1] que no están en #DIA, con montos en 0
     E. Destino[1..D-1] <- llaves de #DIA que no estaban en Destino[D-1]   (llaves nuevas:
        relleno de inicio de mes, montos en 0)
   Como el destino queda completo día a día, Destino[D-1] ES la lista de llaves conocidas:
   no hace falta guardar esa lista en tempdb.

   MEMORIA, TEMPDB, REGISTRO DE TRANSACCIONES Y ESPACIO (lo visto en los errores 9002, 1101 y 2627)
   -------------------------------------------------------------------------------------
   [M1] tempdb guarda solo #CAL (≤ 32 filas) y #DIA (un día, ~3 M de filas). #DIA se vacía
        con TRUNCATE y se recarga con INSERT ... WITH (TABLOCK) (mínimamente registrado).
        No hay #RESULT, ni lista de llaves, ni copias del mes en tempdb.
   [M2] Sin recursión: los días salen de una lista de números (≤ 32 filas).
   [M3] Sin transacciones largas: cada sentencia confirma sola. Las de volumen pueden partirse
        en @N_LOTES lotes y los DELETE van de a @TAM_LOTE_DELETE filas. Así, el registro de
        transacciones de tempdb y de GNBPE_DATAHUB se puede liberar entre sentencias.
   [M4] Merge joins sin memoria extra: #DIA tiene índice agrupado (ID, RUBRO) y la PK del destino
        es (FECHA_PROCESO, ID, RUBRO). Dentro de un día, ambos ya vienen en el mismo orden.
        La única sentencia con ordenamiento grande (la deduplicación del paso B) lleva
        MAX_GRANT_PERCENT: si le falta memoria, desborda a disco de tempdb (datos, no registro)
        en lugar de acaparar RAM.
   [M5] Se rechaza la ejecución dentro de una transacción abierta (@@TRANCOUNT > 0), se fuerza
        IMPLICIT_TRANSACTIONS OFF y se toma sp_getapplock (una sola ejecución a la vez).
   [M6] Validación de la fuente ANTES de borrar nada: si un día hábil trae menos del
        @PCT_MIN_FUENTE del promedio de filas (carga fallida), el SP se detiene en lugar de
        cargar ceros.
   [M7] Idempotente: si falla a mitad, se vuelve a ejecutar el mes y queda correcto.

   [COMPAT] @MODO_COMPATIBLE
   -------------------------------------------------------------------------------------
                                | 1 = igual al original (defecto)        | 0 = corregido
   ANIO/MES de las copias       | del día de ORIGEN (copias del 1/10 = mes 9) | del día generado
   ANIO/MES de los rellenos     | NULL                                   | del día generado
   TIPO_ORIGEN de los rellenos  | NULL                                   | RELLENO_INICIO_MES / RELLENO
   IND_DIA_HABIL de los rellenos| 'S'                                    | el del calendario
   Día ausente en el calendario | relleno en 0                           | copia del último día hábil

   DIFERENCIAS INEVITABLES CON EL ORIGINAL
   -------------------------------------------------------------------------------------
   - Duplicados (ID_OPERACION, COD_RUBRO, fecha) en la fuente: se toma la carga más reciente
     (FECHA_CARGA, BATCH_ID). El original elegía una al azar.
   - El DELETE ya no borra el mismo mes de años anteriores.
   - Filas con ID_OPERACION NULL se excluyen.

   REQUISITOS (ejecutar una vez)
   -------------------------------------------------------------------------------------
   1. PK del destino = (FECHA_PROCESO, ID_OPERACION_CIERRE, COD_RUBRO), clustered
      (script ALTER_PK_PRE_PROMEDIO_LIMPIO.sql). FECHA_PROCESO de tipo DATE.
   2. Índice en la fuente (evita el ordenamiento de la deduplicación y acelera la validación):
        CREATE INDEX IX_BSC_FECHA_OPER ON dbo.BDS_SALDOS_CIERRE
            (FECHA_PROCESO, ID_OPERACION, COD_RUBRO, FECHA_CARGA DESC, BATCH_ID DESC);
   3. Espacio (error 1101): compresión de página en el destino (reduce ~50-70 %):
        ALTER TABLE dbo.BDS_SALDOS_OPERATIVOS_PRE_PROMEDIO_LIMPIO
            REBUILD WITH (DATA_COMPRESSION = PAGE);
   4. tempdb: espacio en los archivos de DATOS para un día (~3 M de filas en #DIA, más los
      posibles desbordes a disco).
   ===================================================================================== */

CREATE OR ALTER PROCEDURE dbo.SP_BDS_SALDOS_OPERATIVOS_PRE_PROMEDIO_H6
    @FECHA_PROCESO      DATE          = NULL,   -- NULL = día anterior
    @MODO_COMPATIBLE    BIT           = 1,      -- 1 = columnas auxiliares iguales al original
    @N_LOTES            INT           = 1,      -- partir C y D en N lotes (1, 4, 8...) si el registro de transacciones se llena
    @TAM_LOTE_DELETE    INT           = 500000, -- filas por DELETE
    @VALIDAR_FUENTE     BIT           = 1,      -- revisar que ningún día hábil venga incompleto
    @PCT_MIN_FUENTE     DECIMAL(5,2)  = 0.50,   -- mínimo aceptado: 50 % del promedio de filas por día hábil
    @VALIDAR_RESULTADO  BIT           = 1       -- al final, revisar que cada llave tenga todos los días
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    SET IMPLICIT_TRANSACTIONS OFF;

    IF @@TRANCOUNT > 0
        THROW 50012, 'No ejecutar este SP dentro de una transacción abierta: confirma por sentencia.', 1;

    IF @FECHA_PROCESO IS NULL SET @FECHA_PROCESO = DATEADD(DAY, -1, CAST(SYSDATETIME() AS DATE));
    IF @N_LOTES IS NULL OR @N_LOTES < 1 SET @N_LOTES = 1;
    IF @TAM_LOTE_DELETE IS NULL OR @TAM_LOTE_DELETE < 10000 SET @TAM_LOTE_DELETE = 500000;

    DECLARE
        @MES_INI         DATE = DATEFROMPARTS(YEAR(@FECHA_PROCESO), MONTH(@FECHA_PROCESO), 1),
        @FECHA_FIN       DATE = @FECHA_PROCESO,
        @SEMILLA         DATE,
        @DIA             DATE,
        @AYER            DATE,
        @ORIGEN          DATE,
        @ORIGEN_CARGADO  DATE = NULL,
        @HABIL           CHAR(1),
        @EN_CAL          BIT,
        @HAY_DATOS       BIT,
        @LOTE            INT,
        @BORRADAS        INT,
        @FASE            VARCHAR(30) = 'INICIO',
        @FILAS           BIGINT = 0,
        @INCOMPLETAS     BIGINT = 0,
        @DIAS_ESPERADOS  INT,
        @MSG             NVARCHAR(4000) = NULL,
        @ID_LOG          BIGINT,
        @LOCK            INT;

    INSERT INTO dbo.ctl_log_proceso (nom_proceso, tabla_origen, tabla_destino, fec_inicio, estado)
    VALUES (N'DATAHUB_BDS_SALDOS_OPERATIVOS_PRE_PROMEDIO', N'BDS_SALDOS_CIERRE',
            N'BDS_SALDOS_OPERATIVOS_PRE_PROMEDIO_LIMPIO', SYSDATETIME(), 'EJECUTANDO');
    SET @ID_LOG = SCOPE_IDENTITY();

    BEGIN TRY
        EXEC @LOCK = sp_getapplock @Resource = 'SP_BDS_SALDOS_OPERATIVOS_PRE_PROMEDIO_H6',
                                   @LockMode = 'Exclusive', @LockOwner = 'Session', @LockTimeout = 0;
        IF @LOCK < 0
            THROW 50011, 'El SP ya se está ejecutando en otra sesión.', 1;

        /* ==============================================================================
           0. CALENDARIO (≤ 32 filas, sin recursión y sin depender de huecos del calendario)
           ============================================================================== */
        SET @FASE = 'CALENDARIO';

        SELECT @SEMILLA = MAX(FEC_CALENDARIO)
        FROM dbo.BDS_CALENDARIOS
        WHERE COD_CALENDARIO = 1
          AND IND_DIA_HABIL  = 'S'
          AND FEC_CALENDARIO <= EOMONTH(@FECHA_FIN, -1);

        IF @SEMILLA IS NULL
            THROW 50010, 'No hay día hábil anterior al mes en BDS_CALENDARIOS (COD_CALENDARIO = 1).', 1;

        ;WITH N AS (
            SELECT TOP (DATEDIFF(DAY, @SEMILLA, @FECHA_FIN) + 1)
                   ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) - 1 AS n
            FROM sys.all_objects
        )
        SELECT
            DATEADD(DAY, N.n, @SEMILLA)                              AS FECHA_PROCESO,
            CAST(CASE WHEN C.FEC IS NULL THEN 0 ELSE 1 END AS BIT)   AS EN_CALENDARIO,
            CAST(ISNULL(C.IND_DIA_HABIL, 'N') AS CHAR(1))            AS IND_DIA_HABIL,
            -- último día hábil <= fecha (de ahí copian los fines de semana y feriados)
            CAST(MAX(CASE WHEN C.IND_DIA_HABIL = 'S' THEN DATEADD(DAY, N.n, @SEMILLA)
                          ELSE CAST('19000101' AS DATE) END)
                 OVER (ORDER BY N.n ROWS UNBOUNDED PRECEDING) AS DATE) AS FECHA_ORIGEN
        INTO #CAL
        FROM N
        LEFT JOIN (
            SELECT CAST(FEC_CALENDARIO AS DATE) AS FEC, MAX(IND_DIA_HABIL) AS IND_DIA_HABIL
            FROM dbo.BDS_CALENDARIOS
            WHERE COD_CALENDARIO = 1
              AND FEC_CALENDARIO BETWEEN @SEMILLA AND @FECHA_FIN
            GROUP BY CAST(FEC_CALENDARIO AS DATE)
        ) C ON C.FEC = DATEADD(DAY, N.n, @SEMILLA);

        CREATE UNIQUE CLUSTERED INDEX IX_CAL ON #CAL (FECHA_PROCESO);

        /* ==============================================================================
           1. VALIDACIÓN DE LA FUENTE (antes de borrar nada)  [M6]
           ============================================================================== */
        IF @VALIDAR_FUENTE = 1
        BEGIN
            SET @FASE = 'VALIDAR_FUENTE';

            DECLARE @DIA_MALO DATE, @FILAS_MALO BIGINT, @PROMEDIO BIGINT;

            ;WITH ORIG AS (                       -- días hábiles que el mes usa como origen
                SELECT DISTINCT FECHA_ORIGEN
                FROM #CAL
                WHERE FECHA_PROCESO >= @MES_INI
                  AND (EN_CALENDARIO = 1 OR @MODO_COMPATIBLE = 0)
            ),
            CNT AS (
                SELECT o.FECHA_ORIGEN,
                       (SELECT COUNT_BIG(*) FROM dbo.BDS_SALDOS_CIERRE s
                        WHERE s.FECHA_PROCESO >= o.FECHA_ORIGEN
                          AND s.FECHA_PROCESO <  DATEADD(DAY, 1, o.FECHA_ORIGEN)) AS FILAS
                FROM ORIG o
            )
            SELECT TOP (1)
                   @DIA_MALO   = FECHA_ORIGEN,
                   @FILAS_MALO = FILAS,
                   @PROMEDIO   = (SELECT AVG(FILAS) FROM CNT)
            FROM CNT
            WHERE FILAS < @PCT_MIN_FUENTE * (SELECT AVG(FILAS) FROM CNT)
            ORDER BY FILAS;

            IF @DIA_MALO IS NOT NULL
            BEGIN
                SET @MSG = CONCAT(N'Fuente incompleta: BDS_SALDOS_CIERRE tiene ', @FILAS_MALO,
                                  N' filas el ', CONVERT(NVARCHAR(10), @DIA_MALO, 23),
                                  N' (promedio ', @PROMEDIO, N'). No se modificó nada.');
                THROW 50013, @MSG, 1;
            END
        END

        /* ==============================================================================
           2. ESTRUCTURA DE #DIA (vacía; se reutiliza con TRUNCATE)  [M1]
           ============================================================================== */
        SELECT TOP (0)
            s.ID_OPERACION AS ID_OPERACION_CIERRE, s.COD_RUBRO,
            s.COD_EMPRESA, s.COD_SUCURSAL, s.COD_MONEDA, s.COD_PAPEL, s.PCT_TASA, s.NUM_CUENTA_BT,
            s.COD_OPERACION, s.COD_EJECUTIVO, s.COD_SUB_OPERACION, s.COD_TIPO_OPERACION, s.COD_MODULO,
            s.COD_MODULO_PRODUCTO, s.FEC_VENCIMIENTO, s.FEC_VALOR, s.IND_CATEGORIA_RIESGO,
            s.COD_ACTI_BCO_CENTRAL, s.COD_PRODUCTO, s.FUENTE,
            s.MTO_SALDO_ORIGEN, s.MTO_SALDO_MN, s.MTO_SALDO_ME, s.MTO_SALDO_MO, s.MTO_INTERES, s.MTO_PREVISIONES
        INTO #DIA
        FROM dbo.BDS_SALDOS_CIERRE s;

        CREATE UNIQUE CLUSTERED INDEX IX_DIA ON #DIA (ID_OPERACION_CIERRE, COD_RUBRO);

        /* Restos de una corrida anterior con fecha posterior dentro del mismo mes */
        SET @FASE = 'LIMPIEZA_RESTOS';
        WHILE 1 = 1
        BEGIN
            DELETE TOP (@TAM_LOTE_DELETE) FROM dbo.BDS_SALDOS_OPERATIVOS_PRE_PROMEDIO_LIMPIO
            WHERE FECHA_PROCESO >  @FECHA_FIN
              AND FECHA_PROCESO <= EOMONTH(@FECHA_FIN);
            IF @@ROWCOUNT < @TAM_LOTE_DELETE BREAK;
        END

        /* ==============================================================================
           3. RECORRIDO DÍA POR DÍA
           ============================================================================== */
        SET @DIA = @MES_INI;

        WHILE @DIA <= @FECHA_FIN
        BEGIN
            SET @AYER = DATEADD(DAY, -1, @DIA);

            SELECT @ORIGEN = FECHA_ORIGEN, @HABIL = IND_DIA_HABIL, @EN_CAL = EN_CALENDARIO
            FROM #CAL WHERE FECHA_PROCESO = @DIA;

            SET @HAY_DATOS = CASE WHEN @ORIGEN = '19000101' THEN 0
                                  WHEN @EN_CAL = 0 AND @MODO_COMPATIBLE = 1 THEN 0
                                  ELSE 1 END;

            /* A. DELETE del día, en lotes */
            SET @FASE = 'A_DELETE';
            WHILE 1 = 1
            BEGIN
                DELETE TOP (@TAM_LOTE_DELETE) FROM dbo.BDS_SALDOS_OPERATIVOS_PRE_PROMEDIO_LIMPIO
                WHERE FECHA_PROCESO = @DIA;
                SET @BORRADAS = @@ROWCOUNT;
                IF @BORRADAS < @TAM_LOTE_DELETE BREAK;
            END

            /* B. Carga del día de origen (solo si cambió) */
            IF @HAY_DATOS = 1 AND (@ORIGEN_CARGADO IS NULL OR @ORIGEN_CARGADO <> @ORIGEN)
            BEGIN
                SET @FASE = 'B_CARGA_DIA';

                TRUNCATE TABLE #DIA;

                INSERT INTO #DIA WITH (TABLOCK) (
                    ID_OPERACION_CIERRE, COD_RUBRO,
                    COD_EMPRESA, COD_SUCURSAL, COD_MONEDA, COD_PAPEL, PCT_TASA, NUM_CUENTA_BT,
                    COD_OPERACION, COD_EJECUTIVO, COD_SUB_OPERACION, COD_TIPO_OPERACION, COD_MODULO,
                    COD_MODULO_PRODUCTO, FEC_VENCIMIENTO, FEC_VALOR, IND_CATEGORIA_RIESGO,
                    COD_ACTI_BCO_CENTRAL, COD_PRODUCTO, FUENTE,
                    MTO_SALDO_ORIGEN, MTO_SALDO_MN, MTO_SALDO_ME, MTO_SALDO_MO, MTO_INTERES, MTO_PREVISIONES)
                SELECT
                    x.ID_OPERACION, x.COD_RUBRO,
                    x.COD_EMPRESA, x.COD_SUCURSAL, x.COD_MONEDA, x.COD_PAPEL, x.PCT_TASA, x.NUM_CUENTA_BT,
                    x.COD_OPERACION, x.COD_EJECUTIVO, x.COD_SUB_OPERACION, x.COD_TIPO_OPERACION, x.COD_MODULO,
                    x.COD_MODULO_PRODUCTO, x.FEC_VENCIMIENTO, x.FEC_VALOR, x.IND_CATEGORIA_RIESGO,
                    x.COD_ACTI_BCO_CENTRAL, x.COD_PRODUCTO, x.FUENTE,
                    x.MTO_SALDO_ORIGEN, x.MTO_SALDO_MN, x.MTO_SALDO_ME, x.MTO_SALDO_MO, x.MTO_INTERES, x.MTO_PREVISIONES
                FROM (
                    SELECT s.*,
                           ROW_NUMBER() OVER (PARTITION BY s.ID_OPERACION, s.COD_RUBRO
                                              ORDER BY s.FECHA_CARGA DESC, s.BATCH_ID DESC) AS RN
                    FROM dbo.BDS_SALDOS_CIERRE s
                    WHERE s.FECHA_PROCESO >= @ORIGEN
                      AND s.FECHA_PROCESO <  DATEADD(DAY, 1, @ORIGEN)
                      AND s.ID_OPERACION IS NOT NULL
                ) x
                WHERE x.RN = 1
                OPTION (MAX_GRANT_PERCENT = 10);            -- [M4] si falta memoria, desborda a disco de tempdb

                SET @ORIGEN_CARGADO = @ORIGEN;
            END

            /* C. ORIGINAL (día hábil) / COPIA_HABIL (fin de semana o feriado) */
            IF @HAY_DATOS = 1
            BEGIN
                SET @FASE = 'C_ORIGINALES';
                SET @LOTE = 0;
                WHILE @LOTE < @N_LOTES
                BEGIN
                    INSERT INTO dbo.BDS_SALDOS_OPERATIVOS_PRE_PROMEDIO_LIMPIO (
                        ID_OPERACION_CIERRE, FECHA_PROCESO, COD_EMPRESA, ANIO, MES, COD_SUCURSAL, COD_RUBRO,
                        COD_MONEDA, COD_PAPEL, PCT_TASA, NUM_CUENTA_BT, COD_OPERACION, COD_EJECUTIVO,
                        COD_SUB_OPERACION, COD_TIPO_OPERACION, COD_MODULO, COD_MODULO_PRODUCTO,
                        FEC_VENCIMIENTO, FEC_VALOR, IND_CATEGORIA_RIESGO, COD_ACTI_BCO_CENTRAL, COD_PRODUCTO,
                        MTO_SALDO_ORIGEN, MTO_SALDO_MN, MTO_SALDO_ME, MTO_SALDO_MO, MTO_INTERES, MTO_PREVISIONES,
                        IND_DIA_HABIL, TIPO_ORIGEN, FUENTE)
                    SELECT
                        d.ID_OPERACION_CIERRE, @DIA, d.COD_EMPRESA,
                        CASE WHEN @MODO_COMPATIBLE = 1 THEN YEAR(@ORIGEN)  ELSE YEAR(@DIA)  END,
                        CASE WHEN @MODO_COMPATIBLE = 1 THEN MONTH(@ORIGEN) ELSE MONTH(@DIA) END,
                        d.COD_SUCURSAL, d.COD_RUBRO,
                        d.COD_MONEDA, d.COD_PAPEL, d.PCT_TASA, d.NUM_CUENTA_BT, d.COD_OPERACION, d.COD_EJECUTIVO,
                        d.COD_SUB_OPERACION, d.COD_TIPO_OPERACION, d.COD_MODULO, d.COD_MODULO_PRODUCTO,
                        d.FEC_VENCIMIENTO, d.FEC_VALOR, d.IND_CATEGORIA_RIESGO, d.COD_ACTI_BCO_CENTRAL, d.COD_PRODUCTO,
                        d.MTO_SALDO_ORIGEN, d.MTO_SALDO_MN, d.MTO_SALDO_ME, d.MTO_SALDO_MO, d.MTO_INTERES, d.MTO_PREVISIONES,
                        @HABIL,
                        CASE WHEN @DIA = @ORIGEN THEN 'ORIGINAL' ELSE 'COPIA_HABIL' END,
                        d.FUENTE
                    FROM #DIA d
                    WHERE @N_LOTES = 1
                       OR (CHECKSUM(d.ID_OPERACION_CIERRE) & 2147483647) % @N_LOTES = @LOTE;

                    SET @FILAS += @@ROWCOUNT;
                    SET @LOTE  += 1;
                END
            END

            /* D. Llaves ya conocidas (están en Destino[ayer]) sin registro hoy → montos en 0
                  (equivale al relleno INTERMEDIO y de FIN DE MES del original) */
            IF @DIA > @MES_INI
            BEGIN
                SET @FASE = 'D_RELLENO';
                SET @LOTE = 0;
                WHILE @LOTE < @N_LOTES
                BEGIN
                    INSERT INTO dbo.BDS_SALDOS_OPERATIVOS_PRE_PROMEDIO_LIMPIO (
                        ID_OPERACION_CIERRE, FECHA_PROCESO, COD_EMPRESA, ANIO, MES, COD_SUCURSAL, COD_RUBRO,
                        COD_MONEDA, COD_PAPEL, PCT_TASA, NUM_CUENTA_BT, COD_OPERACION, COD_EJECUTIVO,
                        COD_SUB_OPERACION, COD_TIPO_OPERACION, COD_MODULO, COD_MODULO_PRODUCTO,
                        FEC_VENCIMIENTO, FEC_VALOR, IND_CATEGORIA_RIESGO, COD_ACTI_BCO_CENTRAL, COD_PRODUCTO,
                        MTO_SALDO_ORIGEN, MTO_SALDO_MN, MTO_SALDO_ME, MTO_SALDO_MO, MTO_INTERES, MTO_PREVISIONES,
                        IND_DIA_HABIL, TIPO_ORIGEN, FUENTE)
                    SELECT
                        p.ID_OPERACION_CIERRE, @DIA, p.COD_EMPRESA,
                        CASE WHEN @MODO_COMPATIBLE = 1 THEN NULL ELSE YEAR(@DIA)  END,
                        CASE WHEN @MODO_COMPATIBLE = 1 THEN NULL ELSE MONTH(@DIA) END,
                        p.COD_SUCURSAL, p.COD_RUBRO,
                        p.COD_MONEDA, p.COD_PAPEL, p.PCT_TASA, p.NUM_CUENTA_BT, p.COD_OPERACION, p.COD_EJECUTIVO,
                        p.COD_SUB_OPERACION, p.COD_TIPO_OPERACION, p.COD_MODULO, p.COD_MODULO_PRODUCTO,
                        p.FEC_VENCIMIENTO, p.FEC_VALOR, p.IND_CATEGORIA_RIESGO, p.COD_ACTI_BCO_CENTRAL, p.COD_PRODUCTO,
                        0, 0, 0, 0, 0, 0,
                        CASE WHEN @MODO_COMPATIBLE = 1 THEN 'S'  ELSE @HABIL   END,
                        CASE WHEN @MODO_COMPATIBLE = 1 THEN NULL ELSE 'RELLENO' END,
                        p.FUENTE
                    FROM dbo.BDS_SALDOS_OPERATIVOS_PRE_PROMEDIO_LIMPIO p
                    WHERE p.FECHA_PROCESO = @AYER
                      AND (@N_LOTES = 1 OR (CHECKSUM(p.ID_OPERACION_CIERRE) & 2147483647) % @N_LOTES = @LOTE)
                      AND (@HAY_DATOS = 0
                           OR NOT EXISTS (SELECT 1 FROM #DIA d
                                          WHERE d.ID_OPERACION_CIERRE = p.ID_OPERACION_CIERRE
                                            AND d.COD_RUBRO           = p.COD_RUBRO));

                    SET @FILAS += @@ROWCOUNT;
                    SET @LOTE  += 1;
                END
            END

            /* E. Llaves NUEVAS (en #DIA pero no en Destino[ayer]) → relleno de INICIO DE MES,
                  del día 1 a ayer, montos en 0 y atributos de su primer registro */
            IF @HAY_DATOS = 1 AND @DIA > @MES_INI
            BEGIN
                SET @FASE = 'E_INICIO_MES';

                INSERT INTO dbo.BDS_SALDOS_OPERATIVOS_PRE_PROMEDIO_LIMPIO (
                    ID_OPERACION_CIERRE, FECHA_PROCESO, COD_EMPRESA, ANIO, MES, COD_SUCURSAL, COD_RUBRO,
                    COD_MONEDA, COD_PAPEL, PCT_TASA, NUM_CUENTA_BT, COD_OPERACION, COD_EJECUTIVO,
                    COD_SUB_OPERACION, COD_TIPO_OPERACION, COD_MODULO, COD_MODULO_PRODUCTO,
                    FEC_VENCIMIENTO, FEC_VALOR, IND_CATEGORIA_RIESGO, COD_ACTI_BCO_CENTRAL, COD_PRODUCTO,
                    MTO_SALDO_ORIGEN, MTO_SALDO_MN, MTO_SALDO_ME, MTO_SALDO_MO, MTO_INTERES, MTO_PREVISIONES,
                    IND_DIA_HABIL, TIPO_ORIGEN, FUENTE)
                SELECT
                    n.ID_OPERACION_CIERRE, c.FECHA_PROCESO, n.COD_EMPRESA,
                    CASE WHEN @MODO_COMPATIBLE = 1 THEN NULL ELSE YEAR(c.FECHA_PROCESO)  END,
                    CASE WHEN @MODO_COMPATIBLE = 1 THEN NULL ELSE MONTH(c.FECHA_PROCESO) END,
                    n.COD_SUCURSAL, n.COD_RUBRO,
                    n.COD_MONEDA, n.COD_PAPEL, n.PCT_TASA, n.NUM_CUENTA_BT, n.COD_OPERACION, n.COD_EJECUTIVO,
                    n.COD_SUB_OPERACION, n.COD_TIPO_OPERACION, n.COD_MODULO, n.COD_MODULO_PRODUCTO,
                    n.FEC_VENCIMIENTO, n.FEC_VALOR, n.IND_CATEGORIA_RIESGO, n.COD_ACTI_BCO_CENTRAL, n.COD_PRODUCTO,
                    0, 0, 0, 0, 0, 0,
                    CASE WHEN @MODO_COMPATIBLE = 1 THEN 'S'  ELSE c.IND_DIA_HABIL        END,
                    CASE WHEN @MODO_COMPATIBLE = 1 THEN NULL ELSE 'RELLENO_INICIO_MES' END,
                    n.FUENTE
                FROM #DIA n
                JOIN #CAL c
                  ON c.FECHA_PROCESO >= @MES_INI
                 AND c.FECHA_PROCESO <  @DIA
                WHERE NOT EXISTS (SELECT 1 FROM dbo.BDS_SALDOS_OPERATIVOS_PRE_PROMEDIO_LIMPIO p
                                  WHERE p.FECHA_PROCESO       = @AYER
                                    AND p.ID_OPERACION_CIERRE = n.ID_OPERACION_CIERRE
                                    AND p.COD_RUBRO           = n.COD_RUBRO);

                SET @FILAS += @@ROWCOUNT;
            END

            SET @DIA = DATEADD(DAY, 1, @DIA);
        END

        /* ==============================================================================
           4. VALIDACIÓN DEL RESULTADO
           ============================================================================== */
        IF @VALIDAR_RESULTADO = 1
        BEGIN
            SET @FASE = 'VALIDAR_RESULTADO';
            SET @DIAS_ESPERADOS = DATEDIFF(DAY, @MES_INI, @FECHA_FIN) + 1;

            SELECT @INCOMPLETAS = COUNT_BIG(*)
            FROM (
                SELECT ID_OPERACION_CIERRE, COD_RUBRO
                FROM dbo.BDS_SALDOS_OPERATIVOS_PRE_PROMEDIO_LIMPIO
                WHERE FECHA_PROCESO >= @MES_INI AND FECHA_PROCESO <= @FECHA_FIN
                GROUP BY ID_OPERACION_CIERRE, COD_RUBRO
                HAVING COUNT(*) <> @DIAS_ESPERADOS
            ) q
            OPTION (MAX_GRANT_PERCENT = 10);
        END

        EXEC sp_releaseapplock @Resource = 'SP_BDS_SALDOS_OPERATIVOS_PRE_PROMEDIO_H6', @LockOwner = 'Session';

        /* ==============================================================================
           5. LOG
           ============================================================================== */
        IF @FILAS = 0
            SET @MSG = N'No se insertaron registros en BDS_SALDOS_OPERATIVOS_PRE_PROMEDIO_LIMPIO.';
        ELSE IF @INCOMPLETAS > 0
            SET @MSG = CONCAT(@INCOMPLETAS, N' llaves (operación, rubro) no tienen ', @DIAS_ESPERADOS, N' días.');

        UPDATE dbo.ctl_log_proceso
           SET estado = CASE WHEN @MSG IS NULL THEN 'TERMINADO' ELSE 'WARNING' END,
               fec_termino = SYSDATETIME(), filas_insertadas = @FILAS, msg_error = @MSG
         WHERE id_log = @ID_LOG;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;

        IF APPLOCK_MODE('public', 'SP_BDS_SALDOS_OPERATIVOS_PRE_PROMEDIO_H6', 'Session') <> 'NoLock'
            EXEC sp_releaseapplock @Resource = 'SP_BDS_SALDOS_OPERATIVOS_PRE_PROMEDIO_H6', @LockOwner = 'Session';

        SET @MSG = CONCAT(N'Error ', ERROR_NUMBER(), N' (línea ', ERROR_LINE(), N'): ', ERROR_MESSAGE(),
                          N' | Fase ', @FASE,
                          CASE WHEN @DIA IS NOT NULL THEN CONCAT(N', día ', CONVERT(NVARCHAR(10), @DIA, 23)) ELSE N'' END,
                          N'. Vuelve a ejecutar el mes.');

        UPDATE dbo.ctl_log_proceso
           SET estado = 'ERROR', fec_termino = SYSDATETIME(), filas_insertadas = @FILAS,
               msg_error = LEFT(@MSG, 4000)
         WHERE id_log = @ID_LOG;

        THROW;
    END CATCH
END;
GO

/* ------------------------------------------------------------------------------------
   Ejecución (fuera de cualquier BEGIN TRAN)
   ------------------------------------------------------------------------------------
   EXEC dbo.SP_BDS_SALDOS_OPERATIVOS_PRE_PROMEDIO_H6 @FECHA_PROCESO = '2026-10-31';                      -- igual al original
   EXEC dbo.SP_BDS_SALDOS_OPERATIVOS_PRE_PROMEDIO_H6 @FECHA_PROCESO = '2026-10-31', @MODO_COMPATIBLE = 0; -- corregido
   EXEC dbo.SP_BDS_SALDOS_OPERATIVOS_PRE_PROMEDIO_H6 @FECHA_PROCESO = '2026-10-31', @N_LOTES = 8;        -- registro de transacciones chico

   Verificación (una sola fila con dias = 31):
   SELECT dias, COUNT(*) AS llaves FROM (
       SELECT ID_OPERACION_CIERRE, COD_RUBRO, COUNT(*) AS dias
       FROM dbo.BDS_SALDOS_OPERATIVOS_PRE_PROMEDIO_LIMPIO
       WHERE FECHA_PROCESO BETWEEN '2026-10-01' AND '2026-10-31'
       GROUP BY ID_OPERACION_CIERRE, COD_RUBRO) t
   GROUP BY dias;
   ------------------------------------------------------------------------------------ */
