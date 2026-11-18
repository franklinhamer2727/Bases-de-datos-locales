/* =====================================================================================
   PROCEDIMIENTO : dbo.SP_BDS_SALDOS_OPERATIVOS_14
   MOTOR         : SQL Server 2016+ (EOMONTH, DATEFROMPARTS, THROW, CREATE OR ALTER: 2016 SP1+)
   DESCRIPCIÓN   : Saldos operativos diarios + promedios acumulados del mes + ingresos /
                   comisiones / gastos / provisiones del mes, cargados en
                   TMP_BDS_SALDOS_OPERATIVOS_H3.

   CAMBIOS RESPECTO A LA VERSIÓN SINGLESTORE
   -------------------------------------------------------------------------------------
   [C01] Fechas calculadas desde @FECHA_PROCESO (antes '2026-03-01' fijo) y filtros por
         rango de fechas (antes MONTH()=V_MES, que mezclaba años y ponía en 0 / NULL el
         mismo mes de años anteriores en el UPDATE).
   [C02] Tablas de trabajo como #temporales: no hay choque entre ejecuciones simultáneas
         y ya no se necesita que UNION_ALL_PS_ACT exista de antemano.
   [C03] TABLA_FINAL_SIN_NOMBRE: 1 lectura con CASE en vez de 6 lecturas + 5 LEFT JOIN.
   [C04] Se eliminan UNION_ALL_PS_ACT_INT / _INT_GP: sus montos eran 0 constantes.
         TEMPORAL_TABLE + UNION_ALL_PS_ACT_GP + TABLA_TEMP1 pasan a ser un solo paso (#OPER_DIA).
   [C05] Las dimensiones por (operación, fecha) se toman de un "rubro principal"
         determinístico (antes el GROUP BY devolvía un valor arbitrario).
   [C06] CRUCE_OPERACIONES: OUTER APPLY TOP 1 (último desembolso <= fecha), de modo que
         no se duplican filas en H3 cuando hay varios plazos.
   [C07] Ingresos / comisiones / gastos / provisiones / castigos / reverso: 1 lectura de
         BDS_SALDOS_CIERRE con SUM condicional, agrupada por ID_OPERACION_CIERRE, y se
         calculan directo en el INSERT (ya no hace falta el UPDATE con 11 LEFT JOIN).
   [C08] Se asigna el reverso de provisiones (antes se cruzaba pero no se usaba).
   [C09] filas_insertadas = @@ROWCOUNT del INSERT (antes era el ROW_COUNT del UPDATE).
   [C10] TRY/CATCH + transacción (DELETE + INSERT atómicos) + log en estado ERROR.
   [C11] sp_getapplock: evita dos ejecuciones concurrentes sobre H3.
   [C12] En SQL Server, CONCAT trata NULL como '': la llave ya no se pierde si un campo es NULL.

   PUNTOS A VALIDAR (marcados con  -- VALIDAR  en el código)
   -------------------------------------------------------------------------------------
   V1. Nombres de columnas de TMP_BDS_SALDOS_OPERATIVOS_H3 (el INSERT ahora lleva lista
       explícita; el original era posicional).
   V2. Columna destino del reverso de provisiones del mes.
   V3. Criterio del "rubro principal" para las dimensiones de la operación.
   V4. Filas de rubros 14xx que también cumplen el filtro de pasivos (doble conteo).
   V5. Fórmula del plazo remanente (+1).
   V6. Formato de la llave concatenada de BDS_SALDOS_CIERRE (numéricos con decimales,
       ceros a la izquierda, etc.) frente al ID_OPERACION_CIERRE de la tabla fuente.
   ===================================================================================== */

CREATE OR ALTER PROCEDURE dbo.SP_BDS_SALDOS_OPERATIVOS_14
    @FECHA_PROCESO DATE
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    /* ---------------------------------------------------------------------------
       Variables  [C01]
       --------------------------------------------------------------------------- */
    DECLARE
        @FEC_INI            DATE = DATEFROMPARTS(YEAR(@FECHA_PROCESO), MONTH(@FECHA_PROCESO), 1),
        @FEC_FIN            DATE = EOMONTH(@FECHA_PROCESO),
        @FEC_FIN_EXCL       DATE = DATEADD(DAY, 1, EOMONTH(@FECHA_PROCESO)),   -- límite exclusivo
        @LAST_DAY_ANTERIOR  DATE = EOMONTH(@FECHA_PROCESO, -1),
        @ES_ENERO           BIT  = CASE WHEN MONTH(@FECHA_PROCESO) = 1 THEN 1 ELSE 0 END,
        @FILAS              BIGINT = 0,
        @MSG_ERROR          NVARCHAR(4000) = NULL,
        @ID_LOG             BIGINT,
        @LOCK_RESULT        INT,
        @NOMBRE_PROCESO     NVARCHAR(200) = N'DATAHUB_BDS_SALDOS_OPERATIVOS',
        @TABLA_ORIGEN       NVARCHAR(400) = N'BDS_SALDOS_OPERATIVOS_PRE_PROMEDIO_LIMPIO, BDS_SALDOS_CIERRE, BDS_OPERACIONES',
        @TABLA_DESTINO      NVARCHAR(200) = N'TMP_BDS_SALDOS_OPERATIVOS_H3';

    /* ---------------------------------------------------------------------------
       Log de inicio (antes: INSERT 'INICIANDO' + UPDATE 'EJECUTANDO')
       --------------------------------------------------------------------------- */
    INSERT INTO dbo.ctl_log_proceso (nom_proceso, tabla_origen, tabla_destino, fec_inicio, estado)
    VALUES (@NOMBRE_PROCESO, @TABLA_ORIGEN, @TABLA_DESTINO, SYSDATETIME(), 'EJECUTANDO');

    SET @ID_LOG = SCOPE_IDENTITY();

    BEGIN TRY

        /* =======================================================================
           1. PARAMETRÍA DE RUBROS DE PASIVOS / RESULTADOS
              Reemplaza las listas LEFT(COD_RUBRO,n) IN (...) y LIKE 'xxx%'.
              - Sin duplicados.
              - Se quitan los prefijos que empiezan con '41': ya los cubre el prefijo '41'.
              Recomendación: llevar esta lista a una tabla física de parametría.
           ======================================================================= */
        CREATE TABLE #PREFIJOS_PASIVO (PREFIJO VARCHAR(30) NOT NULL PRIMARY KEY);

        INSERT INTO #PREFIJOS_PASIVO (PREFIJO)
        SELECT DISTINCT v.PREFIJO
        FROM (VALUES
            -- FA
            ('1111'),('1121'),('1122'),('1112'),('1113'),('1123'),('1124'),('1114'),('1125'),('1115'),
            -- 2 dígitos
            ('56'),('57'),('46'),('49'),('68'),('41'),
            -- 4 dígitos
            ('5121'),('5111'),('5112'),('5114'),('5124'),('5117'),('5127'),('4312'),('4322'),
            ('5211'),('5221'),('5214'),('5224'),('5212'),('5222'),('4211'),('4221'),('4212'),('4222'),
            ('5118'),('5128'),('4511'),('4521'),('4512'),('4522'),('4513'),('4523'),('4514'),('4524'),
            ('4411'),('4421'),('4413'),('4423'),('5213'),('5223'),('4313'),('4323'),
            ('5415'),('5425'),('5416'),('5426'),
            -- 6 dígitos (bloque 1)
            ('512302'),('511302'),('511304'),('512304'),('512305'),('511305'),('511504'),('512504'),
            ('511901'),('512901'),('511925'),('512925'),('521204'),('522204'),('521205'),('522205'),
            ('511916'),('512916'),('511918'),('512918'),('511919'),('512919'),('511926'),('512926'),
            ('511903'),('512903'),('511928'),('512928'),('511507'),('512507'),('511910'),('512910'),
            ('431401'),('432401'),('431402'),('432402'),
            -- 6 dígitos (bloque 2)
            ('511927'),('512927'),('431501'),('432501'),('431502'),('432502'),('431506'),('432506'),
            ('421204'),('422204'),('421205'),('422205'),('511301'),('512301'),('511911'),('512911'),
            ('511912'),('512912'),('511306'),('512306'),('511915'),('512915'),('511303'),('512303'),
            ('511913'),('512913'),('511914'),('512914'),('511917'),('512917'),('511904'),('512904'),
            ('431504'),('432504'),('431503'),('432503'),('431508'),('432508'),('431509'),('432509'),
            -- 8 dígitos
            ('51191703'),('51291703'),('51192403'),('51292403'),
            ('43150501'),('43250501'),('43150505'),('43250505'),('43150506'),('43250506'),
            ('54140103'),('54240103'),
            -- 10 dígitos
            ('5119170102'),('5129170102'),('5119170202'),('5129170202'),('5119240101'),('5129240101'),
            ('5129240102'),   -- VALIDAR: leído de la captura, confirmar que exista en el original
            ('4315050401'),('4325050401'),('4315050402'),('4325050402'),
            -- 16 dígitos (ya los cubre '4312'; se dejan por trazabilidad)
            ('4312030106030101'),('4312030106030501'),('4312030201060101'),
            ('4312030201060501'),('4312030701000103'),('4312030702000103')
        ) v (PREFIJO);

        /* Rubros distintos del mes que cumplen algún prefijo: se evalúa el LIKE sobre
           pocos miles de rubros y no sobre millones de filas. */
        SELECT DISTINCT r.COD_RUBRO
        INTO #RUBROS_PASIVO
        FROM (
            SELECT DISTINCT COD_RUBRO
            FROM dbo.BDS_SALDOS_OPERATIVOS_PRE_PROMEDIO_LIMPIO
            WHERE FECHA_PROCESO >= @FEC_INI AND FECHA_PROCESO < @FEC_FIN_EXCL
        ) r
        WHERE EXISTS (SELECT 1 FROM #PREFIJOS_PASIVO p WHERE r.COD_RUBRO LIKE p.PREFIJO + '%');

        CREATE UNIQUE CLUSTERED INDEX IX_RUBROS_PASIVO ON #RUBROS_PASIVO (COD_RUBRO);

        /* =======================================================================
           2. #UNION_ALL_PS_ACT = ACTIVOS (14xx con buckets) UNION ALL PASIVOS  [C03]
              Bucket según el 4.º dígito del rubro:
                1 = vigente, 3 = restructurado, 4 = refinanciado, 5 = vencido, 6 = judicial
           ======================================================================= */
        SELECT *
        INTO #UNION_ALL_PS_ACT
        FROM (
            /* ---------- ACTIVOS (antes TABLA_FINAL_SIN_NOMBRE) ---------- */
            SELECT DISTINCT
                s.ID_OPERACION_CIERRE,
                CAST(s.FECHA_PROCESO AS DATE)                          AS FECHA_PROCESO,
                s.COD_EMPRESA, s.COD_SUCURSAL, s.COD_RUBRO, s.COD_MONEDA, s.COD_PAPEL,
                s.NUM_CUENTA_BT, s.COD_OPERACION, s.COD_EJECUTIVO, s.COD_SUB_OPERACION,
                s.COD_TIPO_OPERACION, s.COD_MODULO, s.FEC_VENCIMIENTO, s.FEC_VALOR,
                s.IND_CATEGORIA_RIESGO, s.COD_ACTI_BCO_CENTRAL,
                CASE WHEN s.COD_MODULO = 185 AND s.COD_RUBRO LIKE '22_1%' THEN 1
                     WHEN s.COD_MODULO = 183 AND s.COD_RUBRO LIKE '12_1%' THEN 2
                     ELSE 0 END                                        AS TIP_OPERACION,
                s.MTO_SALDO_ORIGEN, s.MTO_SALDO_MN, s.MTO_SALDO_ME, s.MTO_SALDO_MO,
                s.MTO_INTERES, s.MTO_PREVISIONES, s.FUENTE, s.IND_DIA_HABIL,
                CASE WHEN SUBSTRING(s.COD_RUBRO,4,1) = '1' THEN s.MTO_SALDO_MO ELSE 0 END AS MTO_SALDO_VIGENTE_MO,
                CASE WHEN SUBSTRING(s.COD_RUBRO,4,1) = '3' THEN s.MTO_SALDO_MO ELSE 0 END AS MTO_SALDO_RESTRUCTURADO_MO,
                CASE WHEN SUBSTRING(s.COD_RUBRO,4,1) = '4' THEN s.MTO_SALDO_MO ELSE 0 END AS MTO_SALDO_REFINANCIADO_MO,
                CASE WHEN SUBSTRING(s.COD_RUBRO,4,1) = '5' THEN s.MTO_SALDO_MO ELSE 0 END AS MTO_SALDO_VENCIDO_MO,
                CASE WHEN SUBSTRING(s.COD_RUBRO,4,1) = '6' THEN s.MTO_SALDO_MO ELSE 0 END AS MTO_SALDO_JUDICIAL_MO,
                CASE WHEN SUBSTRING(s.COD_RUBRO,4,1) = '1' THEN s.MTO_SALDO_MN ELSE 0 END AS MTO_SALDO_VIGENTE_MN,
                CASE WHEN SUBSTRING(s.COD_RUBRO,4,1) = '3' THEN s.MTO_SALDO_MN ELSE 0 END AS MTO_SALDO_RESTRUCTURADO_MN,
                CASE WHEN SUBSTRING(s.COD_RUBRO,4,1) = '4' THEN s.MTO_SALDO_MN ELSE 0 END AS MTO_SALDO_REFINANCIADO_MN,
                CASE WHEN SUBSTRING(s.COD_RUBRO,4,1) = '5' THEN s.MTO_SALDO_MN ELSE 0 END AS MTO_SALDO_VENCIDO_MN,
                CASE WHEN SUBSTRING(s.COD_RUBRO,4,1) = '6' THEN s.MTO_SALDO_MN ELSE 0 END AS MTO_SALDO_JUDICIAL_MN
            FROM dbo.BDS_SALDOS_OPERATIVOS_PRE_PROMEDIO_LIMPIO s
            WHERE s.FECHA_PROCESO >= @FEC_INI AND s.FECHA_PROCESO < @FEC_FIN_EXCL
              AND LEFT(s.COD_RUBRO, 4) IN ('1401','1403','1404','1405','1406',
                                           '1411','1413','1414','1415','1416',
                                           '1421','1423','1424','1425','1426')

            UNION ALL

            /* ---------- PASIVOS / RESULTADOS (antes TABLA_FINAL_SIN_NOMBRE_PASIVOS) ---------- */
            SELECT
                s.ID_OPERACION_CIERRE,
                CAST(s.FECHA_PROCESO AS DATE),
                s.COD_EMPRESA, s.COD_SUCURSAL, s.COD_RUBRO, s.COD_MONEDA, s.COD_PAPEL,
                s.NUM_CUENTA_BT, s.COD_OPERACION, s.COD_EJECUTIVO, s.COD_SUB_OPERACION,
                s.COD_TIPO_OPERACION, s.COD_MODULO, s.FEC_VENCIMIENTO, s.FEC_VALOR,
                s.IND_CATEGORIA_RIESGO, s.COD_ACTI_BCO_CENTRAL,
                CASE WHEN s.COD_MODULO = 185 AND s.COD_RUBRO LIKE '22_1%' THEN 1
                     WHEN s.COD_MODULO = 183 AND s.COD_RUBRO LIKE '12_1%' THEN 2
                     ELSE 0 END,
                s.MTO_SALDO_ORIGEN, s.MTO_SALDO_MN, s.MTO_SALDO_ME, s.MTO_SALDO_MO,
                s.MTO_INTERES, s.MTO_PREVISIONES, s.FUENTE, s.IND_DIA_HABIL,
                0, 0, 0, 0, 0, 0, 0, 0, 0, 0
            FROM dbo.BDS_SALDOS_OPERATIVOS_PRE_PROMEDIO_LIMPIO s
            WHERE s.FECHA_PROCESO >= @FEC_INI AND s.FECHA_PROCESO < @FEC_FIN_EXCL
              AND (
                       s.COD_RUBRO IN (SELECT COD_RUBRO FROM #RUBROS_PASIVO)
                    OR s.COD_RUBRO LIKE '27_201%'                                        -- FA ('_' es comodín)
                    OR s.COD_MODULO IN (20,120,321,22,185,184,162,155,21)
                    OR (s.COD_MODULO = 183 AND LEFT(s.COD_RUBRO,4) IN ('1201','1211','1221'))
                    OR (s.COD_MODULO = 29  AND s.COD_RUBRO LIKE '71_2%')
                    OR (s.COD_MODULO = 2   AND s.COD_RUBRO LIKE '71_3%')
                  )
              -- VALIDAR (V4): si un rubro 14xx de activos también cumple este filtro (p. ej. por
              -- COD_MODULO), la fila entra dos veces y se suma doble. Para evitarlo, descomentar:
              -- AND LEFT(s.COD_RUBRO,4) NOT IN ('1401','1403','1404','1405','1406','1411','1413','1414',
              --                                 '1415','1416','1421','1423','1424','1425','1426')
        ) u;

        CREATE CLUSTERED INDEX IX_UNION ON #UNION_ALL_PS_ACT (ID_OPERACION_CIERRE, FECHA_PROCESO);

        /* =======================================================================
           3. #OPER_DIA: una fila por (operación, fecha)  [C04] [C05]
              Reemplaza TEMPORAL_TABLE + UNION_ALL_PS_ACT_GP + TABLA_TEMP1.
              Dimensiones: tomadas del "rubro principal".
              VALIDAR (V3): primero los rubros 14 (activo), luego el de mayor |saldo MN|.
           ======================================================================= */
        ;WITH R AS (
            SELECT
                u.*,
                ROW_NUMBER() OVER (
                    PARTITION BY u.ID_OPERACION_CIERRE, u.FECHA_PROCESO
                    ORDER BY CASE WHEN LEFT(u.COD_RUBRO,2) = '14' THEN 0 ELSE 1 END,
                             ABS(u.MTO_SALDO_MN) DESC,
                             u.COD_RUBRO
                ) AS RN,
                SUM(u.MTO_SALDO_ORIGEN)            OVER (PARTITION BY u.ID_OPERACION_CIERRE, u.FECHA_PROCESO) AS S_ORIGEN,
                SUM(u.MTO_SALDO_MN)                OVER (PARTITION BY u.ID_OPERACION_CIERRE, u.FECHA_PROCESO) AS S_MN,
                SUM(u.MTO_SALDO_ME)                OVER (PARTITION BY u.ID_OPERACION_CIERRE, u.FECHA_PROCESO) AS S_ME,
                SUM(u.MTO_SALDO_MO)                OVER (PARTITION BY u.ID_OPERACION_CIERRE, u.FECHA_PROCESO) AS S_MO,
                SUM(u.MTO_INTERES)                 OVER (PARTITION BY u.ID_OPERACION_CIERRE, u.FECHA_PROCESO) AS S_INTERES,
                SUM(u.MTO_PREVISIONES)             OVER (PARTITION BY u.ID_OPERACION_CIERRE, u.FECHA_PROCESO) AS S_PREVISIONES,
                SUM(u.MTO_SALDO_VIGENTE_MO)        OVER (PARTITION BY u.ID_OPERACION_CIERRE, u.FECHA_PROCESO) AS S_VIG_MO,
                SUM(u.MTO_SALDO_RESTRUCTURADO_MO)  OVER (PARTITION BY u.ID_OPERACION_CIERRE, u.FECHA_PROCESO) AS S_RES_MO,
                SUM(u.MTO_SALDO_REFINANCIADO_MO)   OVER (PARTITION BY u.ID_OPERACION_CIERRE, u.FECHA_PROCESO) AS S_REF_MO,
                SUM(u.MTO_SALDO_VENCIDO_MO)        OVER (PARTITION BY u.ID_OPERACION_CIERRE, u.FECHA_PROCESO) AS S_VEN_MO,
                SUM(u.MTO_SALDO_JUDICIAL_MO)       OVER (PARTITION BY u.ID_OPERACION_CIERRE, u.FECHA_PROCESO) AS S_JUD_MO,
                SUM(u.MTO_SALDO_VIGENTE_MN)        OVER (PARTITION BY u.ID_OPERACION_CIERRE, u.FECHA_PROCESO) AS S_VIG_MN,
                SUM(u.MTO_SALDO_RESTRUCTURADO_MN)  OVER (PARTITION BY u.ID_OPERACION_CIERRE, u.FECHA_PROCESO) AS S_RES_MN,
                SUM(u.MTO_SALDO_REFINANCIADO_MN)   OVER (PARTITION BY u.ID_OPERACION_CIERRE, u.FECHA_PROCESO) AS S_REF_MN,
                SUM(u.MTO_SALDO_VENCIDO_MN)        OVER (PARTITION BY u.ID_OPERACION_CIERRE, u.FECHA_PROCESO) AS S_VEN_MN,
                SUM(u.MTO_SALDO_JUDICIAL_MN)       OVER (PARTITION BY u.ID_OPERACION_CIERRE, u.FECHA_PROCESO) AS S_JUD_MN
            FROM #UNION_ALL_PS_ACT u
        )
        SELECT
            r.ID_OPERACION_CIERRE,
            r.FECHA_PROCESO,
            r.COD_EMPRESA, r.COD_SUCURSAL, r.COD_MONEDA, r.COD_PAPEL, r.NUM_CUENTA_BT,
            r.COD_OPERACION, r.COD_EJECUTIVO, r.COD_SUB_OPERACION, r.COD_TIPO_OPERACION,
            r.COD_MODULO,
            CASE SUBSTRING(r.COD_RUBRO,3,1) WHEN '1' THEN 1 WHEN '2' THEN 2 ELSE NULL END AS TIPO_MONEDA,
            r.FEC_VENCIMIENTO, r.FEC_VALOR, r.IND_CATEGORIA_RIESGO, r.COD_ACTI_BCO_CENTRAL,
            r.TIP_OPERACION, r.FUENTE, r.IND_DIA_HABIL,
            DAY(r.FECHA_PROCESO)          AS NUM_DIA_MES,
            DAY(EOMONTH(r.FECHA_PROCESO)) AS TOTAL_DIAS_MES,
            r.S_ORIGEN       AS TOTAL_DIA_SALDO_ORIGEN,
            r.S_MN           AS TOTAL_DIA_SALDO_MN,
            r.S_ME           AS TOTAL_DIA_SALDO_ME,
            r.S_MO           AS TOTAL_DIA_SALDO_MO,
            r.S_INTERES      AS TOTAL_DIA_INTERES,
            r.S_PREVISIONES  AS TOTAL_DIA_PREVISIONES,
            r.S_VIG_MO       AS TOTAL_DIA_SALDO_VIGENTE_MO,
            r.S_RES_MO       AS TOTAL_DIA_SALDO_RESTRUCTURADO_MO,
            r.S_REF_MO       AS TOTAL_DIA_SALDO_REFINANCIADO_MO,
            r.S_VEN_MO       AS TOTAL_DIA_SALDO_VENCIDO_MO,
            r.S_JUD_MO       AS TOTAL_DIA_SALDO_JUDICIAL_MO,
            r.S_VIG_MN       AS TOTAL_DIA_SALDO_VIGENTE_MN,
            r.S_RES_MN       AS TOTAL_DIA_SALDO_RESTRUCTURADO_MN,
            r.S_REF_MN       AS TOTAL_DIA_SALDO_REFINANCIADO_MN,
            r.S_VEN_MN       AS TOTAL_DIA_SALDO_VENCIDO_MN,
            r.S_JUD_MN       AS TOTAL_DIA_SALDO_JUDICIAL_MN
        INTO #OPER_DIA
        FROM R r
        WHERE r.RN = 1;

        CREATE UNIQUE CLUSTERED INDEX IX_OPER_DIA ON #OPER_DIA (ID_OPERACION_CIERRE, FECHA_PROCESO);

        /* =======================================================================
           4. #CIERRE: ingresos, comisiones, gastos, provisiones, reverso y castigos
              por (operación, fecha), desde el cierre del mes anterior hasta fin de mes.  [C07]
              Las cuentas de resultado son acumuladas en el año, así que el monto del mes es:
              acumulado del día - acumulado al cierre del mes anterior (en enero no se resta).
           ======================================================================= */
        SELECT
            k.ID_OPERACION_CIERRE,
            CAST(c.FECHA_PROCESO AS DATE) AS FECHA_PROCESO,
            SUM(CASE WHEN c.COD_RUBRO LIKE '51_4%'     THEN c.MTO_SALDO_MN ELSE 0 END) AS MTO_INGRESO,
            SUM(CASE WHEN c.COD_RUBRO LIKE '51_7%'     THEN c.MTO_SALDO_MN ELSE 0 END) AS MTO_COMISION,
            SUM(CASE WHEN c.COD_RUBRO LIKE '41%'       THEN c.MTO_SALDO_MN ELSE 0 END) AS MTO_GASTO,
            SUM(CASE WHEN c.COD_RUBRO LIKE '54_40103%' THEN c.MTO_SALDO_MN ELSE 0 END) AS MTO_REVERSO,
            SUM(CASE WHEN c.COD_RUBRO LIKE '43_2030106030101%'
                       OR c.COD_RUBRO LIKE '43_2030106030501%'
                       OR c.COD_RUBRO LIKE '43_2030201060101%'
                       OR c.COD_RUBRO LIKE '43_2030201060501%'
                       OR c.COD_RUBRO LIKE '43_2030701000103%'
                       OR c.COD_RUBRO LIKE '43_2030702000103%'
                     THEN c.MTO_SALDO_MN ELSE 0 END)                                    AS MTO_PROVISION,
            SUM(CASE WHEN c.COD_RUBRO IN ('8113020003000001','8113020007000001')
                     THEN c.MTO_SALDO_MN ELSE 0 END)                                    AS MTO_CASTIGADO
        INTO #CIERRE
        FROM dbo.BDS_SALDOS_CIERRE c
        CROSS APPLY (
            -- VALIDAR (V6): la llave debe coincidir con el ID_OPERACION_CIERRE de la fuente
            SELECT CONCAT(c.COD_EMPRESA, '|', c.COD_MODULO_PRODUCTO, '|', c.COD_SUCURSAL, '|',
                          SUBSTRING(c.COD_RUBRO,3,1), '|', c.COD_PAPEL, '|', c.NUM_CUENTA_BT, '|',
                          c.COD_OPERACION, '|', c.COD_SUB_OPERACION, '|', c.COD_TIPO_OPERACION_ORIGEN
                   ) AS ID_OPERACION_CIERRE
        ) k
        WHERE c.FECHA_PROCESO >= @LAST_DAY_ANTERIOR
          AND c.FECHA_PROCESO <  @FEC_FIN_EXCL
          AND (   c.COD_RUBRO LIKE '51%'
               OR c.COD_RUBRO LIKE '41%'
               OR c.COD_RUBRO LIKE '54%'
               OR c.COD_RUBRO LIKE '43%'
               OR c.COD_RUBRO IN ('8113020003000001','8113020007000001'))
        GROUP BY k.ID_OPERACION_CIERRE, CAST(c.FECHA_PROCESO AS DATE);

        CREATE UNIQUE CLUSTERED INDEX IX_CIERRE ON #CIERRE (ID_OPERACION_CIERRE, FECHA_PROCESO);

        /* =======================================================================
           5. CARGA A H3 (DELETE + INSERT atómicos)  [C10] [C11]
           ======================================================================= */
        BEGIN TRANSACTION;

        EXEC @LOCK_RESULT = sp_getapplock
             @Resource    = 'SP_BDS_SALDOS_OPERATIVOS_14',
             @LockMode    = 'Exclusive',
             @LockOwner   = 'Transaction',
             @LockTimeout = 0;

        IF @LOCK_RESULT < 0
            THROW 50001, 'SP_BDS_SALDOS_OPERATIVOS_14 ya se está ejecutando en otra sesión.', 1;

        DELETE FROM dbo.TMP_BDS_SALDOS_OPERATIVOS_H3
        WHERE FECHA_PROCESO >= @FEC_INI
          AND FECHA_PROCESO <  @FEC_FIN_EXCL;

        ;WITH PROM AS (
            /* Promedio acumulado del mes = suma acumulada / día del mes (antes TABLA_2_HAMER_V2).
               Se castea a DECIMAL(38,6) antes de dividir para que no haya división entera. */
            SELECT
                o.*,
                CAST(SUM(CAST(o.TOTAL_DIA_SALDO_ORIGEN AS DECIMAL(38,6))) OVER (PARTITION BY o.ID_OPERACION_CIERRE ORDER BY o.FECHA_PROCESO ROWS UNBOUNDED PRECEDING) / o.NUM_DIA_MES AS DECIMAL(18,4)) AS AVG_SALDO_ORIGEN,
                CAST(SUM(CAST(o.TOTAL_DIA_SALDO_MN     AS DECIMAL(38,6))) OVER (PARTITION BY o.ID_OPERACION_CIERRE ORDER BY o.FECHA_PROCESO ROWS UNBOUNDED PRECEDING) / o.NUM_DIA_MES AS DECIMAL(18,4)) AS AVG_SALDO_MN,
                CAST(SUM(CAST(o.TOTAL_DIA_SALDO_ME     AS DECIMAL(38,6))) OVER (PARTITION BY o.ID_OPERACION_CIERRE ORDER BY o.FECHA_PROCESO ROWS UNBOUNDED PRECEDING) / o.NUM_DIA_MES AS DECIMAL(18,4)) AS AVG_SALDO_ME,
                CAST(SUM(CAST(o.TOTAL_DIA_SALDO_MO     AS DECIMAL(38,6))) OVER (PARTITION BY o.ID_OPERACION_CIERRE ORDER BY o.FECHA_PROCESO ROWS UNBOUNDED PRECEDING) / o.NUM_DIA_MES AS DECIMAL(18,4)) AS AVG_SALDO_MO,
                CAST(SUM(CAST(o.TOTAL_DIA_INTERES      AS DECIMAL(38,6))) OVER (PARTITION BY o.ID_OPERACION_CIERRE ORDER BY o.FECHA_PROCESO ROWS UNBOUNDED PRECEDING) / o.NUM_DIA_MES AS DECIMAL(18,4)) AS AVG_INTERES,
                CAST(SUM(CAST(o.TOTAL_DIA_PREVISIONES  AS DECIMAL(38,6))) OVER (PARTITION BY o.ID_OPERACION_CIERRE ORDER BY o.FECHA_PROCESO ROWS UNBOUNDED PRECEDING) / o.NUM_DIA_MES AS DECIMAL(18,4)) AS AVG_PREVISIONES,
                CAST(SUM(CAST(o.TOTAL_DIA_SALDO_VIGENTE_MO       AS DECIMAL(38,6))) OVER (PARTITION BY o.ID_OPERACION_CIERRE ORDER BY o.FECHA_PROCESO ROWS UNBOUNDED PRECEDING) / o.NUM_DIA_MES AS DECIMAL(18,4)) AS AVG_SALDO_VIGENTE_MO,
                CAST(SUM(CAST(o.TOTAL_DIA_SALDO_RESTRUCTURADO_MO AS DECIMAL(38,6))) OVER (PARTITION BY o.ID_OPERACION_CIERRE ORDER BY o.FECHA_PROCESO ROWS UNBOUNDED PRECEDING) / o.NUM_DIA_MES AS DECIMAL(18,4)) AS AVG_SALDO_RESTRUCTURADO_MO,
                CAST(SUM(CAST(o.TOTAL_DIA_SALDO_REFINANCIADO_MO  AS DECIMAL(38,6))) OVER (PARTITION BY o.ID_OPERACION_CIERRE ORDER BY o.FECHA_PROCESO ROWS UNBOUNDED PRECEDING) / o.NUM_DIA_MES AS DECIMAL(18,4)) AS AVG_SALDO_REFINANCIADO_MO,
                CAST(SUM(CAST(o.TOTAL_DIA_SALDO_VENCIDO_MO       AS DECIMAL(38,6))) OVER (PARTITION BY o.ID_OPERACION_CIERRE ORDER BY o.FECHA_PROCESO ROWS UNBOUNDED PRECEDING) / o.NUM_DIA_MES AS DECIMAL(18,4)) AS AVG_SALDO_VENCIDO_MO,
                CAST(SUM(CAST(o.TOTAL_DIA_SALDO_JUDICIAL_MO      AS DECIMAL(38,6))) OVER (PARTITION BY o.ID_OPERACION_CIERRE ORDER BY o.FECHA_PROCESO ROWS UNBOUNDED PRECEDING) / o.NUM_DIA_MES AS DECIMAL(18,4)) AS AVG_SALDO_JUDICIAL_MO,
                CAST(SUM(CAST(o.TOTAL_DIA_SALDO_VIGENTE_MN       AS DECIMAL(38,6))) OVER (PARTITION BY o.ID_OPERACION_CIERRE ORDER BY o.FECHA_PROCESO ROWS UNBOUNDED PRECEDING) / o.NUM_DIA_MES AS DECIMAL(18,4)) AS AVG_SALDO_VIGENTE_MN,
                CAST(SUM(CAST(o.TOTAL_DIA_SALDO_RESTRUCTURADO_MN AS DECIMAL(38,6))) OVER (PARTITION BY o.ID_OPERACION_CIERRE ORDER BY o.FECHA_PROCESO ROWS UNBOUNDED PRECEDING) / o.NUM_DIA_MES AS DECIMAL(18,4)) AS AVG_SALDO_RESTRUCTURADO_MN,
                CAST(SUM(CAST(o.TOTAL_DIA_SALDO_REFINANCIADO_MN  AS DECIMAL(38,6))) OVER (PARTITION BY o.ID_OPERACION_CIERRE ORDER BY o.FECHA_PROCESO ROWS UNBOUNDED PRECEDING) / o.NUM_DIA_MES AS DECIMAL(18,4)) AS AVG_SALDO_REFINANCIADO_MN,
                CAST(SUM(CAST(o.TOTAL_DIA_SALDO_VENCIDO_MN       AS DECIMAL(38,6))) OVER (PARTITION BY o.ID_OPERACION_CIERRE ORDER BY o.FECHA_PROCESO ROWS UNBOUNDED PRECEDING) / o.NUM_DIA_MES AS DECIMAL(18,4)) AS AVG_SALDO_VENCIDO_MN,
                CAST(SUM(CAST(o.TOTAL_DIA_SALDO_JUDICIAL_MN      AS DECIMAL(38,6))) OVER (PARTITION BY o.ID_OPERACION_CIERRE ORDER BY o.FECHA_PROCESO ROWS UNBOUNDED PRECEDING) / o.NUM_DIA_MES AS DECIMAL(18,4)) AS AVG_SALDO_JUDICIAL_MN
            FROM #OPER_DIA o
        )
        INSERT INTO dbo.TMP_BDS_SALDOS_OPERATIVOS_H3 (     -- VALIDAR (V1): nombres reales de H3
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
            FUENTE, IND_DIA_HABIL
        )
        SELECT
            p.ID_OPERACION_CIERRE,
            p.FECHA_PROCESO,
            EOMONTH(p.FECHA_PROCESO, -1)                                  AS FECHA_CORTE_ULTIMO,
            p.COD_EMPRESA, p.COD_SUCURSAL, p.COD_MONEDA, p.COD_PAPEL, p.NUM_CUENTA_BT, p.COD_OPERACION,
            p.COD_SUB_OPERACION, p.COD_TIPO_OPERACION, p.COD_MODULO, p.TIPO_MONEDA, p.COD_EJECUTIVO,
            p.FEC_VENCIMIENTO, p.FEC_VALOR, p.IND_CATEGORIA_RIESGO, p.COD_ACTI_BCO_CENTRAL, p.TIP_OPERACION,
            p.TOTAL_DIAS_MES,
            p.TOTAL_DIA_SALDO_ORIGEN, p.TOTAL_DIA_SALDO_MN, p.TOTAL_DIA_SALDO_ME, p.TOTAL_DIA_SALDO_MO,
            p.TOTAL_DIA_INTERES, p.TOTAL_DIA_PREVISIONES,
            p.TOTAL_DIA_SALDO_VIGENTE_MO, p.TOTAL_DIA_SALDO_RESTRUCTURADO_MO, p.TOTAL_DIA_SALDO_REFINANCIADO_MO,
            p.TOTAL_DIA_SALDO_VENCIDO_MO, p.TOTAL_DIA_SALDO_JUDICIAL_MO,
            p.TOTAL_DIA_SALDO_VIGENTE_MN, p.TOTAL_DIA_SALDO_RESTRUCTURADO_MN, p.TOTAL_DIA_SALDO_REFINANCIADO_MN,
            p.TOTAL_DIA_SALDO_VENCIDO_MN, p.TOTAL_DIA_SALDO_JUDICIAL_MN,

            -- En el original estas 3 columnas siempre quedaban en 0 (venían de _INT_GP); se conserva.
            0                                                             AS TOTAL_DIA_COMISION_MN,
            0                                                             AS TOTAL_DIA_INGRESO_MN,
            0                                                             AS TOTAL_DIA_GASTO_MN,
            -- VALIDAR (V2): reverso de provisiones del mes [C08]. Si H3 tiene otra columna
            -- para esto, mover el cálculo ahí.
            ISNULL(a.MTO_REVERSO, 0)   - CASE WHEN @ES_ENERO = 1 THEN 0 ELSE ISNULL(b.MTO_REVERSO, 0)   END AS TOTAL_DIA_REVERSO_PROVISION_MN,

            ISNULL(a.MTO_CASTIGADO, 0)                                    AS MTO_CASTIGADO,  -- saldo, sin diferencia
            ISNULL(a.MTO_INGRESO, 0)   - CASE WHEN @ES_ENERO = 1 THEN 0 ELSE ISNULL(b.MTO_INGRESO, 0)   END AS MTO_INGRESO_MN_MES,
            ISNULL(a.MTO_COMISION, 0)  - CASE WHEN @ES_ENERO = 1 THEN 0 ELSE ISNULL(b.MTO_COMISION, 0)  END AS MTO_COMISION_MN_MES,
            ISNULL(a.MTO_GASTO, 0)     - CASE WHEN @ES_ENERO = 1 THEN 0 ELSE ISNULL(b.MTO_GASTO, 0)     END AS MTO_GASTO_MN_MES,
            ISNULL(a.MTO_PROVISION, 0) - CASE WHEN @ES_ENERO = 1 THEN 0 ELSE ISNULL(b.MTO_PROVISION, 0) END AS MTO_PROVISION_MN_MES,

            p.AVG_SALDO_ORIGEN, p.AVG_SALDO_MN, p.AVG_SALDO_ME, p.AVG_SALDO_MO,
            p.AVG_INTERES, p.AVG_PREVISIONES,
            p.AVG_SALDO_VIGENTE_MO, p.AVG_SALDO_RESTRUCTURADO_MO, p.AVG_SALDO_REFINANCIADO_MO,
            p.AVG_SALDO_VENCIDO_MO, p.AVG_SALDO_JUDICIAL_MO,
            p.AVG_SALDO_VIGENTE_MN, p.AVG_SALDO_RESTRUCTURADO_MN, p.AVG_SALDO_REFINANCIADO_MN,
            p.AVG_SALDO_VENCIDO_MN, p.AVG_SALDO_JUDICIAL_MN,

            cro.FECHA_REFERENCIA                                          AS FECHA_DESEMBOLSO,
            -- VALIDAR (V5): se mantiene la fórmula original  plazo - días transcurridos + 1
            CASE WHEN cro.NUM_DIAS_PLAZO - DATEDIFF(DAY, cro.FECHA_REFERENCIA, p.FECHA_PROCESO) + 1 < 0
                 THEN 0
                 ELSE cro.NUM_DIAS_PLAZO - DATEDIFF(DAY, cro.FECHA_REFERENCIA, p.FECHA_PROCESO) + 1
            END                                                           AS PLA_REMANENTE,

            p.FUENTE,
            p.IND_DIA_HABIL
        FROM PROM p
        LEFT JOIN #CIERRE a                                   -- acumulado del día
               ON a.ID_OPERACION_CIERRE = p.ID_OPERACION_CIERRE
              AND a.FECHA_PROCESO       = p.FECHA_PROCESO
        LEFT JOIN #CIERRE b                                   -- acumulado al cierre del mes anterior
               ON b.ID_OPERACION_CIERRE = p.ID_OPERACION_CIERRE
              AND b.FECHA_PROCESO       = @LAST_DAY_ANTERIOR
        OUTER APPLY (                                         -- [C06] último desembolso <= fecha
            SELECT TOP (1)
                   COALESCE(bp.FECHA_DESEMBOLSO, bp.FEC_ALTA) AS FECHA_REFERENCIA,
                   bp.NUM_DIAS_PLAZO
            FROM dbo.BDS_OPERACIONES bp
            WHERE bp.ID_OPERACION = p.ID_OPERACION_CIERRE
              AND COALESCE(bp.FECHA_DESEMBOLSO, bp.FEC_ALTA) <= p.FECHA_PROCESO
            ORDER BY COALESCE(bp.FECHA_DESEMBOLSO, bp.FEC_ALTA) DESC, bp.NUM_DIAS_PLAZO DESC
        ) cro;

        SET @FILAS = @@ROWCOUNT;   -- [C09] filas insertadas en H3

        COMMIT TRANSACTION;

        /* ---------------------------------------------------------------------------
           Log de fin
           --------------------------------------------------------------------------- */
        IF @FILAS = 0
            SET @MSG_ERROR = N'No se insertaron registros en TMP_BDS_SALDOS_OPERATIVOS_H3 para '
                           + CONVERT(NVARCHAR(7), @FEC_INI, 126) + N'.';

        UPDATE dbo.ctl_log_proceso
           SET estado           = CASE WHEN @MSG_ERROR IS NULL THEN 'TERMINADO' ELSE 'WARNING' END,
               fec_termino      = SYSDATETIME(),
               filas_insertadas = @FILAS,
               msg_error        = @MSG_ERROR
         WHERE id_log = @ID_LOG;

    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0
            ROLLBACK TRANSACTION;

        SET @MSG_ERROR = CONCAT(N'Error ', ERROR_NUMBER(), N' (línea ', ERROR_LINE(), N'): ', ERROR_MESSAGE());

        UPDATE dbo.ctl_log_proceso
           SET estado      = 'ERROR',
               fec_termino = SYSDATETIME(),
               msg_error   = LEFT(@MSG_ERROR, 4000)
         WHERE id_log = @ID_LOG;

        THROW;
    END CATCH
END;
GO

/* ------------------------------------------------------------------------------------
   Índices recomendados en las tablas físicas (si no existen)
   ------------------------------------------------------------------------------------
   CREATE INDEX IX_PPL_FECHA_RUBRO ON dbo.BDS_SALDOS_OPERATIVOS_PRE_PROMEDIO_LIMPIO (FECHA_PROCESO, COD_RUBRO);
   CREATE INDEX IX_CIERRE_FECHA    ON dbo.BDS_SALDOS_CIERRE (FECHA_PROCESO, COD_RUBRO) INCLUDE (MTO_SALDO_MN);
   CREATE INDEX IX_OPER_ID_FECHA   ON dbo.BDS_OPERACIONES (ID_OPERACION, FECHA_DESEMBOLSO, FEC_ALTA) INCLUDE (NUM_DIAS_PLAZO);
   CREATE INDEX IX_H3_FECHA        ON dbo.TMP_BDS_SALDOS_OPERATIVOS_H3 (FECHA_PROCESO);

   Ejecución:
   EXEC dbo.SP_BDS_SALDOS_OPERATIVOS_14 @FECHA_PROCESO = '2026-10-31';
   ------------------------------------------------------------------------------------ */
