/* =====================================================================================
   PROCEDIMIENTO : dbo.SP_BDS_SALDOS_OPERATIVOS_14        (versión 2: día por día)
   MOTOR         : SQL Server 2016 SP1+
   FUENTE        : dbo.BDS_SALDOS_OPERATIVOS_PRE_PROMEDIO_LIMPIO (densa: cada operación/rubro
                   todos los días, generada por SP_BDS_SALDOS_OPERATIVOS_PRE_PROMEDIO_H6)
   DESTINO       : dbo.TMP_BDS_SALDOS_OPERATIVOS_H3

   POR QUÉ SE REESCRIBIÓ (error 9002 en tempdb, línea 167 de la v1)
   -------------------------------------------------------------------------------------
   La v1 copiaba TODO el mes de PRE_PROMEDIO (~93 M de filas) a #UNION_ALL_PS_ACT, con
   DISTINCT, SUM() OVER y promedios con ventana sobre el mes completo, y cargaba H3 en una
   sola transacción. Todo eso vive en tempdb al mismo tiempo.

   CÓMO FUNCIONA AHORA (un día por vuelta, mismo resultado)
   -------------------------------------------------------------------------------------
   El promedio acumulado del día D es:  suma de los días 1..D / DAY(D).
   En vez de una ventana sobre el mes, se guarda la suma acumulada por operación en #ACUM
   y se le suma el día de cada vuelta:
     1. #OPER_D  <- PRE_PROMEDIO[D] clasificado en activos / pasivos y agregado por operación
                    (sumas + dimensiones del "rubro principal")
     2. #ACUM    <- #ACUM + #OPER_D                  (sumas acumuladas del mes)
     3. #CRO     <- desembolsos con fecha D          (estado de plazo por operación)
     4. #CIERRE_D<- BDS_SALDOS_CIERRE[D] (ingresos, comisiones, gastos, provisiones, reverso,
                    castigos). Si D no tiene datos (fin de semana o feriado), se reutiliza
                    el último día con datos.
     5. H3[D]    <- DELETE en lotes + INSERT (#OPER_D + #ACUM/DAY(D) + #CIERRE_D - #CIERRE_ANT + #CRO)

   MEMORIA / TEMPDB / REGISTRO DE TRANSACCIONES
   -------------------------------------------------------------------------------------
   [M1] tempdb guarda como máximo: un día agregado (#OPER_D), las sumas acumuladas (#ACUM),
        el estado de desembolsos (#CRO) y el cierre del día / del mes anterior. Todo con una
        fila por operación, nunca el mes completo.
   [M2] Sin funciones de ventana sobre el mes ni DISTINCT sobre 93 M de filas.
   [M3] Cada sentencia confirma sola. La actualización de #ACUM (la única pesada en el registro
        de tempdb) va en @N_LOTES lotes. El DELETE de H3 va de a @TAM_LOTE_DELETE filas.
   [M4] La lectura del día en PRE_PROMEDIO es un rango contiguo de su PK
        (FECHA_PROCESO, ID, RUBRO): ya viene ordenada por operación, así que la agregación
        por operación no necesita ordenar. Los ordenamientos que quedan llevan MAX_GRANT_PERCENT.
   [M5] Se rechaza la ejecución dentro de una transacción abierta, se fuerza
        IMPLICIT_TRANSACTIONS OFF y se toma sp_getapplock.
   [M6] La clasificación de rubros (prefijos LIKE) se evalúa una sola vez por rubro distinto
        (#RUBROS), no por fila.

   CAMBIOS DE LÓGICA RESPECTO A LA v1 (busca  -- VALIDAR)
   -------------------------------------------------------------------------------------
   [L1] Llave de BDS_SALDOS_CIERRE = ID_OPERACION (igual que en H6), sin CONCAT.
   [L2] Días sin datos en BDS_SALDOS_CIERRE (fines de semana y feriados): se usa el último
        día con datos. Antes ese día quedaba como 0 - (acumulado del mes anterior), es decir,
        un ingreso NEGATIVO en fines de semana.
   [L3] El cierre del mes anterior se toma del último día con datos <= fin del mes anterior.
   [L4] Se quita el DISTINCT de activos: la PK de PRE_PROMEDIO ya garantiza filas únicas.
   Todo lo demás (buckets por 4.º dígito, filtro de pasivos, rubro principal, promedios,
   plazo remanente, diferencia contra el mes anterior y enero) se mantiene igual que en la v1.

   REQUISITOS
   -------------------------------------------------------------------------------------
   - PK de PRE_PROMEDIO = (FECHA_PROCESO, ID_OPERACION_CIERRE, COD_RUBRO), FECHA_PROCESO DATE.
   - Índices recomendados:
       CREATE INDEX IX_BSC_FECHA_RUBRO ON dbo.BDS_SALDOS_CIERRE (FECHA_PROCESO, COD_RUBRO)
              INCLUDE (ID_OPERACION, MTO_SALDO_MN);
       CREATE INDEX IX_H3_FECHA ON dbo.TMP_BDS_SALDOS_OPERATIVOS_H3 (FECHA_PROCESO);
       -- (mejor aún: PK/clustered de H3 en (FECHA_PROCESO, ID_OPERACION_CIERRE))
   ===================================================================================== */

CREATE OR ALTER PROCEDURE dbo.SP_BDS_SALDOS_OPERATIVOS_14
    @FECHA_PROCESO    DATE = NULL,     -- NULL = día anterior
    @N_LOTES          INT  = 4,        -- lotes para actualizar #ACUM (sube a 8/16 si tempdb es chico)
    @TAM_LOTE_DELETE  INT  = 500000
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    SET IMPLICIT_TRANSACTIONS OFF;

    IF @@TRANCOUNT > 0
        THROW 50012, 'No ejecutar este SP dentro de una transacción abierta.', 1;

    IF @FECHA_PROCESO IS NULL SET @FECHA_PROCESO = DATEADD(DAY, -1, CAST(SYSDATETIME() AS DATE));
    IF @N_LOTES IS NULL OR @N_LOTES < 1 SET @N_LOTES = 1;
    IF @TAM_LOTE_DELETE IS NULL OR @TAM_LOTE_DELETE < 10000 SET @TAM_LOTE_DELETE = 500000;

    DECLARE
        @FEC_INI            DATE = DATEFROMPARTS(YEAR(@FECHA_PROCESO), MONTH(@FECHA_PROCESO), 1),
        @FECHA_FIN          DATE = @FECHA_PROCESO,
        @LAST_DAY_ANTERIOR  DATE = EOMONTH(@FECHA_PROCESO, -1),
        @FECHA_ANT_DATOS    DATE,
        @ES_ENERO           BIT  = CASE WHEN MONTH(@FECHA_PROCESO) = 1 THEN 1 ELSE 0 END,
        @TOTAL_DIAS_MES     INT  = DAY(EOMONTH(@FECHA_PROCESO)),
        @DIA                DATE,
        @FECHA_CIERRE       DATE,           -- día de BDS_SALDOS_CIERRE que se va a cargar
        @CIERRE_CARGADO     DATE = NULL,
        @LOTE               INT,
        @FASE               VARCHAR(30) = 'INICIO',
        @FILAS              BIGINT = 0,
        @MSG                NVARCHAR(4000) = NULL,
        @ID_LOG             BIGINT,
        @LOCK               INT;

    INSERT INTO dbo.ctl_log_proceso (nom_proceso, tabla_origen, tabla_destino, fec_inicio, estado)
    VALUES (N'DATAHUB_BDS_SALDOS_OPERATIVOS',
            N'BDS_SALDOS_OPERATIVOS_PRE_PROMEDIO_LIMPIO, BDS_SALDOS_CIERRE, BDS_OPERACIONES',
            N'TMP_BDS_SALDOS_OPERATIVOS_H3', SYSDATETIME(), 'EJECUTANDO');
    SET @ID_LOG = SCOPE_IDENTITY();

    BEGIN TRY
        EXEC @LOCK = sp_getapplock @Resource = 'SP_BDS_SALDOS_OPERATIVOS_14', @LockMode = 'Exclusive',
                                   @LockOwner = 'Session', @LockTimeout = 0;
        IF @LOCK < 0 THROW 50011, 'El SP ya se está ejecutando en otra sesión.', 1;

        /* ==============================================================================
           0. PARAMETRÍA DE RUBROS (se evalúa una vez por rubro distinto)  [M6]
           ============================================================================== */
        SET @FASE = 'PARAMETRIA';

        CREATE TABLE #PREFIJOS_PASIVO (PREFIJO VARCHAR(30) NOT NULL PRIMARY KEY);

        INSERT INTO #PREFIJOS_PASIVO (PREFIJO)
        SELECT DISTINCT v.PREFIJO
        FROM (VALUES
            ('1111'),('1121'),('1122'),('1112'),('1113'),('1123'),('1124'),('1114'),('1125'),('1115'),
            ('56'),('57'),('46'),('49'),('68'),('41'),
            ('5121'),('5111'),('5112'),('5114'),('5124'),('5117'),('5127'),('4312'),('4322'),
            ('5211'),('5221'),('5214'),('5224'),('5212'),('5222'),('4211'),('4221'),('4212'),('4222'),
            ('5118'),('5128'),('4511'),('4521'),('4512'),('4522'),('4513'),('4523'),('4514'),('4524'),
            ('4411'),('4421'),('4413'),('4423'),('5213'),('5223'),('4313'),('4323'),
            ('5415'),('5425'),('5416'),('5426'),
            ('512302'),('511302'),('511304'),('512304'),('512305'),('511305'),('511504'),('512504'),
            ('511901'),('512901'),('511925'),('512925'),('521204'),('522204'),('521205'),('522205'),
            ('511916'),('512916'),('511918'),('512918'),('511919'),('512919'),('511926'),('512926'),
            ('511903'),('512903'),('511928'),('512928'),('511507'),('512507'),('511910'),('512910'),
            ('431401'),('432401'),('431402'),('432402'),
            ('511927'),('512927'),('431501'),('432501'),('431502'),('432502'),('431506'),('432506'),
            ('421204'),('422204'),('421205'),('422205'),('511301'),('512301'),('511911'),('512911'),
            ('511912'),('512912'),('511306'),('512306'),('511915'),('512915'),('511303'),('512303'),
            ('511913'),('512913'),('511914'),('512914'),('511917'),('512917'),('511904'),('512904'),
            ('431504'),('432504'),('431503'),('432503'),('431508'),('432508'),('431509'),('432509'),
            ('51191703'),('51291703'),('51192403'),('51292403'),
            ('43150501'),('43250501'),('43150505'),('43250505'),('43150506'),('43250506'),
            ('54140103'),('54240103'),
            ('5119170102'),('5129170102'),('5119170202'),('5129170202'),('5119240101'),('5129240101'),
            ('5129240102'),   -- VALIDAR: leído de la captura original
            ('4315050401'),('4325050401'),('4315050402'),('4325050402'),
            ('4312030106030101'),('4312030106030501'),('4312030201060101'),
            ('4312030201060501'),('4312030701000103'),('4312030702000103')
        ) v (PREFIJO);

        -- Clasificación por rubro (se completa día a día con los rubros nuevos)
        CREATE TABLE #RUBROS (
            COD_RUBRO        VARCHAR(50) NOT NULL PRIMARY KEY,
            ES_ACTIVO        BIT     NOT NULL,   -- 14xx con bucket
            ES_PASIVO_RUBRO  BIT     NOT NULL,   -- parte del filtro de pasivos que depende solo del rubro
            DIG4             CHAR(1) NULL,       -- 1 vig, 3 restr, 4 refin, 5 venc, 6 judicial
            ES_14            BIT     NOT NULL,   -- para el "rubro principal"
            ES_22_1          BIT     NOT NULL,   -- TIP_OPERACION = 1 (con módulo 185)
            ES_12_1          BIT     NOT NULL,   -- TIP_OPERACION = 2 (con módulo 183)
            ES_1201_1221     BIT     NOT NULL,   -- pasivo con módulo 183
            ES_71_2          BIT     NOT NULL,   -- pasivo con módulo 29
            ES_71_3          BIT     NOT NULL,   -- pasivo con módulo 2
            TIPO_MONEDA      INT     NULL
        );

        /* ==============================================================================
           1. ESTADO INICIAL: cierre del mes anterior y desembolsos
           ============================================================================== */
        SET @FASE = 'ESTADO_INICIAL';

        -- [L3] último día con datos <= fin del mes anterior
        SELECT @FECHA_ANT_DATOS = MAX(FECHA_PROCESO)
        FROM dbo.BDS_SALDOS_CIERRE
        WHERE FECHA_PROCESO <= @LAST_DAY_ANTERIOR
          AND FECHA_PROCESO >  DATEADD(DAY, -15, @LAST_DAY_ANTERIOR);

        -- Acumulados al cierre del mes anterior (para restar; en enero no se usan)
        SELECT
            c.ID_OPERACION AS ID_OPERACION_CIERRE,                                  -- [L1] VALIDAR
            SUM(CASE WHEN c.COD_RUBRO LIKE '51_4%'     THEN c.MTO_SALDO_MN ELSE 0 END) AS MTO_INGRESO,
            SUM(CASE WHEN c.COD_RUBRO LIKE '51_7%'     THEN c.MTO_SALDO_MN ELSE 0 END) AS MTO_COMISION,
            SUM(CASE WHEN c.COD_RUBRO LIKE '41%'       THEN c.MTO_SALDO_MN ELSE 0 END) AS MTO_GASTO,
            SUM(CASE WHEN c.COD_RUBRO LIKE '54_40103%' THEN c.MTO_SALDO_MN ELSE 0 END) AS MTO_REVERSO,
            SUM(CASE WHEN c.COD_RUBRO LIKE '43_2030106030101%' OR c.COD_RUBRO LIKE '43_2030106030501%'
                       OR c.COD_RUBRO LIKE '43_2030201060101%' OR c.COD_RUBRO LIKE '43_2030201060501%'
                       OR c.COD_RUBRO LIKE '43_2030701000103%' OR c.COD_RUBRO LIKE '43_2030702000103%'
                     THEN c.MTO_SALDO_MN ELSE 0 END) AS MTO_PROVISION
        INTO #CIERRE_ANT
        FROM dbo.BDS_SALDOS_CIERRE c
        WHERE @ES_ENERO = 0
          AND c.FECHA_PROCESO = @FECHA_ANT_DATOS
          AND c.ID_OPERACION IS NOT NULL
          AND (c.COD_RUBRO LIKE '51%' OR c.COD_RUBRO LIKE '41%' OR c.COD_RUBRO LIKE '54%' OR c.COD_RUBRO LIKE '43%')
        GROUP BY c.ID_OPERACION;

        CREATE UNIQUE CLUSTERED INDEX IX_CIERRE_ANT ON #CIERRE_ANT (ID_OPERACION_CIERRE);

        -- Desembolsos: estado al inicio del mes (último desembolso anterior al día 1)
        SELECT x.ID_OPERACION AS ID_OPERACION_CIERRE, x.FECHA_REFERENCIA, x.NUM_DIAS_PLAZO
        INTO #CRO
        FROM (
            SELECT bp.ID_OPERACION,
                   COALESCE(bp.FECHA_DESEMBOLSO, bp.FEC_ALTA) AS FECHA_REFERENCIA,
                   bp.NUM_DIAS_PLAZO,
                   ROW_NUMBER() OVER (PARTITION BY bp.ID_OPERACION
                                      ORDER BY COALESCE(bp.FECHA_DESEMBOLSO, bp.FEC_ALTA) DESC,
                                               bp.NUM_DIAS_PLAZO DESC) AS RN
            FROM dbo.BDS_OPERACIONES bp
            WHERE COALESCE(bp.FECHA_DESEMBOLSO, bp.FEC_ALTA) < @FEC_INI
              AND bp.ID_OPERACION IS NOT NULL
        ) x
        WHERE x.RN = 1
        OPTION (MAX_GRANT_PERCENT = 10);

        CREATE UNIQUE CLUSTERED INDEX IX_CRO ON #CRO (ID_OPERACION_CIERRE);

        -- Desembolsos DENTRO del mes (pocos): se aplican el día que ocurren
        SELECT x.ID_OPERACION AS ID_OPERACION_CIERRE, x.FECHA_REFERENCIA, x.NUM_DIAS_PLAZO
        INTO #EVENTOS
        FROM (
            SELECT bp.ID_OPERACION,
                   CAST(COALESCE(bp.FECHA_DESEMBOLSO, bp.FEC_ALTA) AS DATE) AS FECHA_REFERENCIA,
                   bp.NUM_DIAS_PLAZO,
                   ROW_NUMBER() OVER (PARTITION BY bp.ID_OPERACION, CAST(COALESCE(bp.FECHA_DESEMBOLSO, bp.FEC_ALTA) AS DATE)
                                      ORDER BY bp.NUM_DIAS_PLAZO DESC) AS RN
            FROM dbo.BDS_OPERACIONES bp
            WHERE COALESCE(bp.FECHA_DESEMBOLSO, bp.FEC_ALTA) >= @FEC_INI
              AND COALESCE(bp.FECHA_DESEMBOLSO, bp.FEC_ALTA) <  DATEADD(DAY, 1, @FECHA_FIN)
              AND bp.ID_OPERACION IS NOT NULL
        ) x
        WHERE x.RN = 1;

        CREATE CLUSTERED INDEX IX_EVENTOS ON #EVENTOS (FECHA_REFERENCIA, ID_OPERACION_CIERRE);

        -- Sumas acumuladas del mes por operación (se llena el día 1 y se suma cada día)
        CREATE TABLE #ACUM (
            ID_OPERACION_CIERRE VARCHAR(200) NOT NULL PRIMARY KEY,   -- VALIDAR largo vs PRE_PROMEDIO
            A_ORIGEN DECIMAL(38,6) NOT NULL, A_MN DECIMAL(38,6) NOT NULL, A_ME DECIMAL(38,6) NOT NULL,
            A_MO DECIMAL(38,6) NOT NULL, A_INTERES DECIMAL(38,6) NOT NULL, A_PREVISIONES DECIMAL(38,6) NOT NULL,
            A_VIG_MO DECIMAL(38,6) NOT NULL, A_RES_MO DECIMAL(38,6) NOT NULL, A_REF_MO DECIMAL(38,6) NOT NULL,
            A_VEN_MO DECIMAL(38,6) NOT NULL, A_JUD_MO DECIMAL(38,6) NOT NULL,
            A_VIG_MN DECIMAL(38,6) NOT NULL, A_RES_MN DECIMAL(38,6) NOT NULL, A_REF_MN DECIMAL(38,6) NOT NULL,
            A_VEN_MN DECIMAL(38,6) NOT NULL, A_JUD_MN DECIMAL(38,6) NOT NULL
        );

        -- Restos en H3 de una corrida anterior con fecha posterior dentro del mismo mes
        WHILE 1 = 1
        BEGIN
            DELETE TOP (@TAM_LOTE_DELETE) FROM dbo.TMP_BDS_SALDOS_OPERATIVOS_H3
            WHERE FECHA_PROCESO > @FECHA_FIN AND FECHA_PROCESO <= EOMONTH(@FECHA_FIN);
            IF @@ROWCOUNT < @TAM_LOTE_DELETE BREAK;
        END

        /* ==============================================================================
           2. RECORRIDO DÍA POR DÍA
           ============================================================================== */
        SET @DIA = @FEC_INI;

        WHILE @DIA <= @FECHA_FIN
        BEGIN
            /* 2.1 Rubros nuevos del día → clasificación (LIKE solo sobre rubros nuevos) */
            SET @FASE = 'RUBROS';
            INSERT INTO #RUBROS
            SELECT
                r.COD_RUBRO,
                CASE WHEN LEFT(r.COD_RUBRO,4) IN ('1401','1403','1404','1405','1406','1411','1413','1414',
                                                  '1415','1416','1421','1423','1424','1425','1426') THEN 1 ELSE 0 END,
                CASE WHEN EXISTS (SELECT 1 FROM #PREFIJOS_PASIVO p WHERE r.COD_RUBRO LIKE p.PREFIJO + '%')
                       OR r.COD_RUBRO LIKE '27_201%' THEN 1 ELSE 0 END,
                SUBSTRING(r.COD_RUBRO, 4, 1),
                CASE WHEN LEFT(r.COD_RUBRO,2) = '14' THEN 1 ELSE 0 END,
                CASE WHEN r.COD_RUBRO LIKE '22_1%' THEN 1 ELSE 0 END,
                CASE WHEN r.COD_RUBRO LIKE '12_1%' THEN 1 ELSE 0 END,
                CASE WHEN LEFT(r.COD_RUBRO,4) IN ('1201','1211','1221') THEN 1 ELSE 0 END,
                CASE WHEN r.COD_RUBRO LIKE '71_2%' THEN 1 ELSE 0 END,
                CASE WHEN r.COD_RUBRO LIKE '71_3%' THEN 1 ELSE 0 END,
                CASE SUBSTRING(r.COD_RUBRO,3,1) WHEN '1' THEN 1 WHEN '2' THEN 2 ELSE NULL END
            FROM (SELECT DISTINCT p.COD_RUBRO
                  FROM dbo.BDS_SALDOS_OPERATIVOS_PRE_PROMEDIO_LIMPIO p
                  WHERE p.FECHA_PROCESO = @DIA) r
            WHERE NOT EXISTS (SELECT 1 FROM #RUBROS x WHERE x.COD_RUBRO = r.COD_RUBRO);

            /* 2.2 #OPER_D: el día agregado por operación (activos UNION ALL pasivos, en una lectura) */
            SET @FASE = 'OPER_DIA';
            IF OBJECT_ID('tempdb..#OPER_D') IS NOT NULL DROP TABLE #OPER_D;

            ;WITH X AS (
                -- Una fila de PRE_PROMEDIO cuenta como ACTIVO (T=1), como PASIVO (T=2) o como ambas
                -- (mismo comportamiento que el UNION ALL original)
                SELECT
                    p.ID_OPERACION_CIERRE, p.COD_RUBRO,
                    p.COD_EMPRESA, p.COD_SUCURSAL, p.COD_MONEDA, p.COD_PAPEL, p.NUM_CUENTA_BT,
                    p.COD_OPERACION, p.COD_EJECUTIVO, p.COD_SUB_OPERACION, p.COD_TIPO_OPERACION, p.COD_MODULO,
                    p.FEC_VENCIMIENTO, p.FEC_VALOR, p.IND_CATEGORIA_RIESGO, p.COD_ACTI_BCO_CENTRAL,
                    p.FUENTE, p.IND_DIA_HABIL,
                    p.MTO_SALDO_ORIGEN, p.MTO_SALDO_MN, p.MTO_SALDO_ME, p.MTO_SALDO_MO, p.MTO_INTERES, p.MTO_PREVISIONES,
                    r.DIG4, r.ES_14, r.TIPO_MONEDA,
                    CASE WHEN p.COD_MODULO = 185 AND r.ES_22_1 = 1 THEN 1
                         WHEN p.COD_MODULO = 183 AND r.ES_12_1 = 1 THEN 2
                         ELSE 0 END AS TIP_OPERACION,
                    t.T
                FROM dbo.BDS_SALDOS_OPERATIVOS_PRE_PROMEDIO_LIMPIO p
                JOIN #RUBROS r ON r.COD_RUBRO = p.COD_RUBRO
                CROSS APPLY (VALUES (1), (2)) t (T)
                WHERE p.FECHA_PROCESO = @DIA
                  AND (   (t.T = 1 AND r.ES_ACTIVO = 1)
                       OR (t.T = 2 AND (   r.ES_PASIVO_RUBRO = 1
                                        OR p.COD_MODULO IN (20,120,321,22,185,184,162,155,21)
                                        OR (p.COD_MODULO = 183 AND r.ES_1201_1221 = 1)
                                        OR (p.COD_MODULO = 29  AND r.ES_71_2 = 1)
                                        OR (p.COD_MODULO = 2   AND r.ES_71_3 = 1))))
            ),
            S AS (   -- sumas del día por operación
                SELECT
                    ID_OPERACION_CIERRE,
                    SUM(MTO_SALDO_ORIGEN) AS S_ORIGEN, SUM(MTO_SALDO_MN) AS S_MN, SUM(MTO_SALDO_ME) AS S_ME,
                    SUM(MTO_SALDO_MO) AS S_MO, SUM(MTO_INTERES) AS S_INTERES, SUM(MTO_PREVISIONES) AS S_PREVISIONES,
                    SUM(CASE WHEN T = 1 AND DIG4 = '1' THEN MTO_SALDO_MO ELSE 0 END) AS S_VIG_MO,
                    SUM(CASE WHEN T = 1 AND DIG4 = '3' THEN MTO_SALDO_MO ELSE 0 END) AS S_RES_MO,
                    SUM(CASE WHEN T = 1 AND DIG4 = '4' THEN MTO_SALDO_MO ELSE 0 END) AS S_REF_MO,
                    SUM(CASE WHEN T = 1 AND DIG4 = '5' THEN MTO_SALDO_MO ELSE 0 END) AS S_VEN_MO,
                    SUM(CASE WHEN T = 1 AND DIG4 = '6' THEN MTO_SALDO_MO ELSE 0 END) AS S_JUD_MO,
                    SUM(CASE WHEN T = 1 AND DIG4 = '1' THEN MTO_SALDO_MN ELSE 0 END) AS S_VIG_MN,
                    SUM(CASE WHEN T = 1 AND DIG4 = '3' THEN MTO_SALDO_MN ELSE 0 END) AS S_RES_MN,
                    SUM(CASE WHEN T = 1 AND DIG4 = '4' THEN MTO_SALDO_MN ELSE 0 END) AS S_REF_MN,
                    SUM(CASE WHEN T = 1 AND DIG4 = '5' THEN MTO_SALDO_MN ELSE 0 END) AS S_VEN_MN,
                    SUM(CASE WHEN T = 1 AND DIG4 = '6' THEN MTO_SALDO_MN ELSE 0 END) AS S_JUD_MN
                FROM X
                GROUP BY ID_OPERACION_CIERRE
            ),
            P AS (   -- "rubro principal": primero 14xx, luego mayor |saldo MN|, luego rubro
                SELECT X.*,
                       ROW_NUMBER() OVER (PARTITION BY ID_OPERACION_CIERRE
                                          ORDER BY ES_14 DESC, ABS(MTO_SALDO_MN) DESC, COD_RUBRO) AS RN
                FROM X
            )
            SELECT
                P.ID_OPERACION_CIERRE,
                P.COD_EMPRESA, P.COD_SUCURSAL, P.COD_MONEDA, P.COD_PAPEL, P.NUM_CUENTA_BT,
                P.COD_OPERACION, P.COD_EJECUTIVO, P.COD_SUB_OPERACION, P.COD_TIPO_OPERACION, P.COD_MODULO,
                P.TIPO_MONEDA, P.FEC_VENCIMIENTO, P.FEC_VALOR, P.IND_CATEGORIA_RIESGO, P.COD_ACTI_BCO_CENTRAL,
                P.TIP_OPERACION, P.FUENTE, P.IND_DIA_HABIL,
                S.S_ORIGEN, S.S_MN, S.S_ME, S.S_MO, S.S_INTERES, S.S_PREVISIONES,
                S.S_VIG_MO, S.S_RES_MO, S.S_REF_MO, S.S_VEN_MO, S.S_JUD_MO,
                S.S_VIG_MN, S.S_RES_MN, S.S_REF_MN, S.S_VEN_MN, S.S_JUD_MN
            INTO #OPER_D
            FROM P
            JOIN S ON S.ID_OPERACION_CIERRE = P.ID_OPERACION_CIERRE
            WHERE P.RN = 1
            OPTION (MAX_GRANT_PERCENT = 10);

            CREATE UNIQUE CLUSTERED INDEX IX_OPER_D ON #OPER_D (ID_OPERACION_CIERRE);

            /* 2.3 #ACUM += día (en lotes: es la única escritura pesada en el registro de tempdb) */
            SET @FASE = 'ACUM';
            SET @LOTE = 0;
            WHILE @LOTE < @N_LOTES
            BEGIN
                UPDATE a SET
                    a.A_ORIGEN += ISNULL(d.S_ORIGEN,0), a.A_MN += ISNULL(d.S_MN,0),
                    a.A_ME += ISNULL(d.S_ME,0), a.A_MO += ISNULL(d.S_MO,0),
                    a.A_INTERES += ISNULL(d.S_INTERES,0), a.A_PREVISIONES += ISNULL(d.S_PREVISIONES,0),
                    a.A_VIG_MO += d.S_VIG_MO, a.A_RES_MO += d.S_RES_MO, a.A_REF_MO += d.S_REF_MO,
                    a.A_VEN_MO += d.S_VEN_MO, a.A_JUD_MO += d.S_JUD_MO,
                    a.A_VIG_MN += d.S_VIG_MN, a.A_RES_MN += d.S_RES_MN, a.A_REF_MN += d.S_REF_MN,
                    a.A_VEN_MN += d.S_VEN_MN, a.A_JUD_MN += d.S_JUD_MN
                FROM #ACUM a
                JOIN #OPER_D d ON d.ID_OPERACION_CIERRE = a.ID_OPERACION_CIERRE
                WHERE @N_LOTES = 1 OR (CHECKSUM(a.ID_OPERACION_CIERRE) & 2147483647) % @N_LOTES = @LOTE;
                SET @LOTE += 1;
            END

            -- Operaciones que aparecen por primera vez (con H6 denso, casi todas el día 1)
            INSERT INTO #ACUM WITH (TABLOCK)
            SELECT d.ID_OPERACION_CIERRE,
                   ISNULL(d.S_ORIGEN,0), ISNULL(d.S_MN,0), ISNULL(d.S_ME,0), ISNULL(d.S_MO,0),
                   ISNULL(d.S_INTERES,0), ISNULL(d.S_PREVISIONES,0),
                   d.S_VIG_MO, d.S_RES_MO, d.S_REF_MO, d.S_VEN_MO, d.S_JUD_MO,
                   d.S_VIG_MN, d.S_RES_MN, d.S_REF_MN, d.S_VEN_MN, d.S_JUD_MN
            FROM #OPER_D d
            WHERE NOT EXISTS (SELECT 1 FROM #ACUM a WHERE a.ID_OPERACION_CIERRE = d.ID_OPERACION_CIERRE);

            /* 2.4 Desembolsos del día → estado de plazo */
            SET @FASE = 'DESEMBOLSOS';
            UPDATE c SET c.FECHA_REFERENCIA = e.FECHA_REFERENCIA, c.NUM_DIAS_PLAZO = e.NUM_DIAS_PLAZO
            FROM #CRO c
            JOIN #EVENTOS e ON e.ID_OPERACION_CIERRE = c.ID_OPERACION_CIERRE AND e.FECHA_REFERENCIA = @DIA;

            INSERT INTO #CRO (ID_OPERACION_CIERRE, FECHA_REFERENCIA, NUM_DIAS_PLAZO)
            SELECT e.ID_OPERACION_CIERRE, e.FECHA_REFERENCIA, e.NUM_DIAS_PLAZO
            FROM #EVENTOS e
            WHERE e.FECHA_REFERENCIA = @DIA
              AND NOT EXISTS (SELECT 1 FROM #CRO c WHERE c.ID_OPERACION_CIERRE = e.ID_OPERACION_CIERRE);

            /* 2.5 Cierre del día (si no hay datos: fin de semana / feriado → se reutiliza el último)  [L2] */
            SET @FASE = 'CIERRE_DIA';
            SET @FECHA_CIERRE = NULL;
            IF EXISTS (SELECT 1 FROM dbo.BDS_SALDOS_CIERRE WHERE FECHA_PROCESO = @DIA)
                SET @FECHA_CIERRE = @DIA;                          -- día con datos
            ELSE IF @CIERRE_CARGADO IS NULL
                -- Primer día del mes sin datos (p. ej. día 1 feriado): se parte del cierre del mes
                -- anterior (diferencia 0). En enero el acumulado anual se reinicia: se parte de 0.
                SET @FECHA_CIERRE = CASE WHEN @ES_ENERO = 1 THEN @DIA ELSE @FECHA_ANT_DATOS END;
            -- si no, se reutiliza #CIERRE_D del último día con datos

            IF @FECHA_CIERRE IS NOT NULL
            BEGIN
                IF OBJECT_ID('tempdb..#CIERRE_D') IS NOT NULL DROP TABLE #CIERRE_D;

                SELECT
                    c.ID_OPERACION AS ID_OPERACION_CIERRE,                              -- [L1] VALIDAR
                    SUM(CASE WHEN c.COD_RUBRO LIKE '51_4%'     THEN c.MTO_SALDO_MN ELSE 0 END) AS MTO_INGRESO,
                    SUM(CASE WHEN c.COD_RUBRO LIKE '51_7%'     THEN c.MTO_SALDO_MN ELSE 0 END) AS MTO_COMISION,
                    SUM(CASE WHEN c.COD_RUBRO LIKE '41%'       THEN c.MTO_SALDO_MN ELSE 0 END) AS MTO_GASTO,
                    SUM(CASE WHEN c.COD_RUBRO LIKE '54_40103%' THEN c.MTO_SALDO_MN ELSE 0 END) AS MTO_REVERSO,
                    SUM(CASE WHEN c.COD_RUBRO LIKE '43_2030106030101%' OR c.COD_RUBRO LIKE '43_2030106030501%'
                               OR c.COD_RUBRO LIKE '43_2030201060101%' OR c.COD_RUBRO LIKE '43_2030201060501%'
                               OR c.COD_RUBRO LIKE '43_2030701000103%' OR c.COD_RUBRO LIKE '43_2030702000103%'
                             THEN c.MTO_SALDO_MN ELSE 0 END) AS MTO_PROVISION,
                    SUM(CASE WHEN c.COD_RUBRO IN ('8113020003000001','8113020007000001')
                             THEN c.MTO_SALDO_MN ELSE 0 END) AS MTO_CASTIGADO
                INTO #CIERRE_D
                FROM dbo.BDS_SALDOS_CIERRE c
                WHERE c.FECHA_PROCESO = @FECHA_CIERRE
                  AND c.ID_OPERACION IS NOT NULL
                  AND (c.COD_RUBRO LIKE '51%' OR c.COD_RUBRO LIKE '41%' OR c.COD_RUBRO LIKE '54%'
                       OR c.COD_RUBRO LIKE '43%' OR c.COD_RUBRO IN ('8113020003000001','8113020007000001'))
                GROUP BY c.ID_OPERACION
                OPTION (MAX_GRANT_PERCENT = 10);

                CREATE UNIQUE CLUSTERED INDEX IX_CIERRE_D ON #CIERRE_D (ID_OPERACION_CIERRE);
                SET @CIERRE_CARGADO = @FECHA_CIERRE;
            END

            /* 2.6 H3 del día: DELETE en lotes + INSERT */
            SET @FASE = 'H3';
            WHILE 1 = 1
            BEGIN
                DELETE TOP (@TAM_LOTE_DELETE) FROM dbo.TMP_BDS_SALDOS_OPERATIVOS_H3
                WHERE FECHA_PROCESO = @DIA;
                IF @@ROWCOUNT < @TAM_LOTE_DELETE BREAK;
            END

            INSERT INTO dbo.TMP_BDS_SALDOS_OPERATIVOS_H3 (     -- VALIDAR: nombres reales de H3
                ID_OPERACION_CIERRE, FECHA_PROCESO, FECHA_CORTE_ULTIMO,
                COD_EMPRESA, COD_SUCURSAL, COD_MONEDA, COD_PAPEL, NUM_CUENTA_BT, COD_OPERACION,
                COD_SUB_OPERACION, COD_TIPO_OPERACION, COD_MODULO, TIPO_MONEDA, COD_EJECUTIVO,
                FEC_VENCIMIENTO, FEC_VALOR, IND_CATEGORIA_RIESGO, COD_ACTI_BCO_CENTRAL, TIP_OPERACION,
                TOTAL_DIAS_MES,
                TOTAL_MTO_SALDO_ORIGEN, TOTAL_MTO_SALDO_MN, TOTAL_MTO_SALDO_ME, TOTAL_MTO_SALDO_MO,
                TOTAL_MTO_INTERES, TOTAL_MTO_PREVISIONES,
                TOTAL_MTO_SALDO_VIGENTE_MO, TOTAL_MTO_SALDO_RESTRUCTURADO_MO, TOTAL_MTO_SALDO_REFINANCIADO_MO,
                TOTAL_MTO_SALDO_VENCIDO_MO, TOTAL_MTO_SALDO_JUDICIAL_MO,
                TOTAL_MTO_SALDO_VIGENTE_MN, TOTAL_MTO_SALDO_RESTRUCTURADO_MN, TOTAL_MTO_SALDO_REFINANCIADO_MN,
                TOTAL_MTO_SALDO_VENCIDO_MN, TOTAL_MTO_SALDO_JUDICIAL_MN,
                TOTAL_DIA_COMISION_MN, TOTAL_DIA_INGRESO_MN, TOTAL_DIA_GASTO_MN, TOTAL_DIA_REVERSO_PROVISION_MN,
                MTO_CASTIGADO,
                MTO_INGRESO_MN_MES, MTO_COMISION_MN_MES, MTO_GASTO_MN_MES, MTO_PROVISION_MN_MES,
                TOTAL_AVG_SALDO_ORIGEN, TOTAL_AVG_SALDO_MN, TOTAL_AVG_SALDO_ME, TOTAL_AVG_SALDO_MO,
                TOTAL_AVG_INTERES, TOTAL_AVG_PREVISIONES,
                TOTAL_AVG_SALDO_VIGENTE_MO, TOTAL_AVG_SALDO_RESTRUCTURADO_MO, TOTAL_AVG_SALDO_REFINANCIADO_MO,
                TOTAL_AVG_SALDO_VENCIDO_MO, TOTAL_AVG_SALDO_JUDICIAL_MO,
                TOTAL_AVG_SALDO_VIGENTE_MN, TOTAL_AVG_SALDO_RESTRUCTURADO_MN, TOTAL_AVG_SALDO_REFINANCIADO_MN,
                TOTAL_AVG_SALDO_VENCIDO_MN, TOTAL_AVG_SALDO_JUDICIAL_MN,
                FECHA_DESEMBOLSO, PLA_REMANENTE,
                FUENTE, IND_DIA_HABIL)
            SELECT
                d.ID_OPERACION_CIERRE, @DIA, @LAST_DAY_ANTERIOR,
                d.COD_EMPRESA, d.COD_SUCURSAL, d.COD_MONEDA, d.COD_PAPEL, d.NUM_CUENTA_BT, d.COD_OPERACION,
                d.COD_SUB_OPERACION, d.COD_TIPO_OPERACION, d.COD_MODULO, d.TIPO_MONEDA, d.COD_EJECUTIVO,
                d.FEC_VENCIMIENTO, d.FEC_VALOR, d.IND_CATEGORIA_RIESGO, d.COD_ACTI_BCO_CENTRAL, d.TIP_OPERACION,
                @TOTAL_DIAS_MES,
                d.S_ORIGEN, d.S_MN, d.S_ME, d.S_MO, d.S_INTERES, d.S_PREVISIONES,
                d.S_VIG_MO, d.S_RES_MO, d.S_REF_MO, d.S_VEN_MO, d.S_JUD_MO,
                d.S_VIG_MN, d.S_RES_MN, d.S_REF_MN, d.S_VEN_MN, d.S_JUD_MN,
                0, 0, 0,                                                   -- siempre 0 en el original
                ISNULL(ca.MTO_REVERSO, 0)   - ISNULL(cb.MTO_REVERSO, 0),   -- VALIDAR: columna del reverso
                ISNULL(ca.MTO_CASTIGADO, 0),
                ISNULL(ca.MTO_INGRESO, 0)   - ISNULL(cb.MTO_INGRESO, 0),
                ISNULL(ca.MTO_COMISION, 0)  - ISNULL(cb.MTO_COMISION, 0),
                ISNULL(ca.MTO_GASTO, 0)     - ISNULL(cb.MTO_GASTO, 0),
                ISNULL(ca.MTO_PROVISION, 0) - ISNULL(cb.MTO_PROVISION, 0),
                -- Promedio acumulado = suma de los días 1..D / DAY(D)
                CAST(a.A_ORIGEN      / DAY(@DIA) AS DECIMAL(18,4)), CAST(a.A_MN        / DAY(@DIA) AS DECIMAL(18,4)),
                CAST(a.A_ME          / DAY(@DIA) AS DECIMAL(18,4)), CAST(a.A_MO        / DAY(@DIA) AS DECIMAL(18,4)),
                CAST(a.A_INTERES     / DAY(@DIA) AS DECIMAL(18,4)), CAST(a.A_PREVISIONES / DAY(@DIA) AS DECIMAL(18,4)),
                CAST(a.A_VIG_MO      / DAY(@DIA) AS DECIMAL(18,4)), CAST(a.A_RES_MO    / DAY(@DIA) AS DECIMAL(18,4)),
                CAST(a.A_REF_MO      / DAY(@DIA) AS DECIMAL(18,4)), CAST(a.A_VEN_MO    / DAY(@DIA) AS DECIMAL(18,4)),
                CAST(a.A_JUD_MO      / DAY(@DIA) AS DECIMAL(18,4)),
                CAST(a.A_VIG_MN      / DAY(@DIA) AS DECIMAL(18,4)), CAST(a.A_RES_MN    / DAY(@DIA) AS DECIMAL(18,4)),
                CAST(a.A_REF_MN      / DAY(@DIA) AS DECIMAL(18,4)), CAST(a.A_VEN_MN    / DAY(@DIA) AS DECIMAL(18,4)),
                CAST(a.A_JUD_MN      / DAY(@DIA) AS DECIMAL(18,4)),
                c.FECHA_REFERENCIA,
                CASE WHEN c.NUM_DIAS_PLAZO - DATEDIFF(DAY, c.FECHA_REFERENCIA, @DIA) + 1 < 0 THEN 0
                     ELSE c.NUM_DIAS_PLAZO - DATEDIFF(DAY, c.FECHA_REFERENCIA, @DIA) + 1 END,   -- VALIDAR (+1)
                d.FUENTE, d.IND_DIA_HABIL
            FROM #OPER_D d
            JOIN #ACUM a            ON a.ID_OPERACION_CIERRE  = d.ID_OPERACION_CIERRE
            LEFT JOIN #CIERRE_D ca  ON ca.ID_OPERACION_CIERRE = d.ID_OPERACION_CIERRE
            LEFT JOIN #CIERRE_ANT cb ON cb.ID_OPERACION_CIERRE = d.ID_OPERACION_CIERRE   -- vacía en enero
            LEFT JOIN #CRO c        ON c.ID_OPERACION_CIERRE  = d.ID_OPERACION_CIERRE;

            SET @FILAS += @@ROWCOUNT;
            SET @DIA = DATEADD(DAY, 1, @DIA);
        END

        EXEC sp_releaseapplock @Resource = 'SP_BDS_SALDOS_OPERATIVOS_14', @LockOwner = 'Session';

        IF @FILAS = 0
            SET @MSG = N'No se insertaron registros en TMP_BDS_SALDOS_OPERATIVOS_H3.';

        UPDATE dbo.ctl_log_proceso
           SET estado = CASE WHEN @MSG IS NULL THEN 'TERMINADO' ELSE 'WARNING' END,
               fec_termino = SYSDATETIME(), filas_insertadas = @FILAS, msg_error = @MSG
         WHERE id_log = @ID_LOG;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;

        IF APPLOCK_MODE('public', 'SP_BDS_SALDOS_OPERATIVOS_14', 'Session') <> 'NoLock'
            EXEC sp_releaseapplock @Resource = 'SP_BDS_SALDOS_OPERATIVOS_14', @LockOwner = 'Session';

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
   Ejecución (fuera de cualquier BEGIN TRAN; después de SP_BDS_SALDOS_OPERATIVOS_PRE_PROMEDIO_H6)
   EXEC dbo.SP_BDS_SALDOS_OPERATIVOS_14 @FECHA_PROCESO = '2026-10-31';
   EXEC dbo.SP_BDS_SALDOS_OPERATIVOS_14 @FECHA_PROCESO = '2026-10-31', @N_LOTES = 8;   -- tempdb chico
   ------------------------------------------------------------------------------------ */
