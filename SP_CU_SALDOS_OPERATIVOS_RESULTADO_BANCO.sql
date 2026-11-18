/* =====================================================================================
   PROCEDIMIENTO : SP_CU_SALDOS_OPERATIVOS_RESULTADO_BANCO
   MOTOR         : SingleStore
   PARÁMETRO     : P_FECHA_PROCESO -> cualquier día del mes a procesar (se usa su LAST_DAY)

   QUÉ HACE
   -------------------------------------------------------------------------------------
   PASO 1. CU_SALDOS_OPERATIVOS_RESULTADO_BANCO
           Saldos operativos al cierre del mes, ya enriquecidos con banca, segmento,
           parámetros MFB y nombre del módulo (antes eran INSERT + 3 UPDATE).
   PASO 2. CU_SALDOS_OPERATIVOS_RESULTADO_BANCO_CONSOLIDADO
           2A. Cartera + Fondeo: cada rama del UNION ALL original es una "REGLA".
           2B. Inversiones / Filiales / Liquidez: fuentes diarias, saldo al cierre y
               promedio del mes.

   CAMBIOS RESPECTO AL SCRIPT ORIGINAL
   -------------------------------------------------------------------------------------
   [C01] Procesa UN mes (DELETE + INSERT de ese cierre). Antes cada corrida volvía a
         insertar todos los cierres históricos en CU (duplicados) y reconstruía el
         CONSOLIDADO completo con DROP + CREATE.
   [C02] Los UPDATE de BDS_EJECUTIVOS, ODS_PARAMETROS_MFB y BDS_MODULO ahora son JOIN
         dentro del INSERT. Antes actualizaban toda la tabla CU, todos los meses.
   [C03] Las tablas de cruce se deduplican antes del JOIN para que no multipliquen montos:
         BDS_OPERACIONES (activas), BDS_EJECUTIVOS, ODS_PARAMETROS_MFB, ODS_CUENTA,
         ODS_MODULO_PRODUCTO y BDS_CONSOLIDADO_SBS_BT.
   [C04] Las ~22 ramas de cartera/fondeo, que repetían el mismo bloque de 25 SUM, son
         ahora una tabla de reglas (R) más un solo bloque de agregación. Para agregar una
         rama nueva: una fila en R, un flag RNN en la base y, si sus niveles son
         dinámicos, un WHEN en el CASE.
   [C05] Inversiones / Liquidez: se leen solo los días del mes. El saldo es el del cierre
         y el promedio es AVG de los días del mes; equivale a la última fila de la
         ventana SUM()/COUNT(*) original. Antes estas ramas insertaban TODOS los días de
         la historia en el CONSOLIDADO; ahora solo la fila del cierre.
   [C06] Log en ctl_log_proceso con TERMINADO / WARNING / ERROR, transacción y manejo de
         excepciones.

   PUNTOS A VALIDAR (busca  -- VALIDAR  y  -- PENDIENTE  en el código)
   -------------------------------------------------------------------------------------
   V1. PENDIENTE: faltan partes del script en las capturas:
       a) el filtro de la rama 'CDs IFIs' (TL_CODFAMILIA = ?);
       b) la rama entre 'Fondos Interbancarios - Otros Ingresos' y 'Fondeo - Personas - Plazo'
          (falta una captura entre ambas).
   V2. CU_..._CONSOLIDADO debe existir antes de la primera ejecución: créala una vez con el
       CREATE TABLE ... AS del script original, o con un DDL fijo.
   V3. La deduplicación usa MAX() cuando hay más de una fila por llave. Si el original
       tenía duplicados, los montos van a bajar, porque antes se sumaban dos veces.
   V4. Las ramas de inversiones usan '' en COD_MODULO / NUM_CUENTA_BT, igual que el
       original. Si esas columnas son numéricas en la tabla, cambia '' por NULL.
   ===================================================================================== */

DELIMITER //

CREATE OR REPLACE PROCEDURE SP_CU_SALDOS_OPERATIVOS_RESULTADO_BANCO(P_FECHA_PROCESO DATE)
AS
DECLARE
    V_FECHA_CIERRE   DATE;
    V_FEC_INI        DATE;
    V_FILAS_CU       BIGINT = 0;
    V_FILAS_CONS     BIGINT = 0;
    V_ID_LOG         BIGINT;
    V_MSG            LONGTEXT = NULL;
BEGIN
    V_FECHA_CIERRE = LAST_DAY(P_FECHA_PROCESO);
    V_FEC_INI      = DATE_SUB(V_FECHA_CIERRE, INTERVAL DAY(V_FECHA_CIERRE) - 1 DAY);

    INSERT INTO ctl_log_proceso (nom_proceso, tabla_origen, tabla_destino, fec_inicio, estado)
    VALUES ('DATAHUB_CU_SALDOS_OPERATIVOS_RESULTADO_BANCO',
            'BDS_SALDOS_OPERATIVOS',
            'CU_SALDOS_OPERATIVOS_RESULTADO_BANCO / _CONSOLIDADO',
            NOW(6), 'EJECUTANDO');
    V_ID_LOG = LAST_INSERT_ID();

    START TRANSACTION;

    /* ==================================================================================
       PASO 1. CU_SALDOS_OPERATIVOS_RESULTADO_BANCO (cierre del mes)
       ================================================================================== */
    DELETE FROM CU_SALDOS_OPERATIVOS_RESULTADO_BANCO
    WHERE FECHA_PROCESO = V_FECHA_CIERRE;

    INSERT INTO CU_SALDOS_OPERATIVOS_RESULTADO_BANCO (
        FECHA_PROCESO, COD_MODULO, COD_CONVENIO, NUM_CUENTA_BT, COD_OPERACION,
        COD_EJECUTIVO, COD_TIPO_OPERACION, ID_OPERACION_CIERRE,
        TOTAL_MTO_SALDO_MO, TOTAL_MTO_SALDO_MN, TOTAL_MTO_SALDO_ME,
        TOTAL_AVG_SALDO_MO, TOTAL_AVG_SALDO_MN, TOTAL_AVG_SALDO_ME,
        TOTAL_MTO_SALDO_X_TASA_MO, TOTAL_MTO_SALDO_X_TASA_MN, TOTAL_MTO_SALDO_X_TASA_ME,
        TOTAL_MTO_SALDO_X_TASA_COF_MO, TOTAL_MTO_SALDO_X_TASA_COF_MN, TOTAL_MTO_SALDO_X_TASA_COF_ME,
        TOTAL_MTO_VENCIDO_MO, TOTAL_MTO_VENCIDO_MN,
        TOTAL_MTO_REFINANCIADO_MO, TOTAL_MTO_REFINANCIADO_MN,
        TOTAL_MTO_JUDICIAL_MO, TOTAL_MTO_JUDICIAL_MN,
        TOTAL_MTO_PROVISIONES,
        -- antes se llenaban con UPDATE
        NUM_BANCA, NUM_SEGMENTO,
        DES_TIPO, DES_BANCA, DES_BANCA_CLASIFICACION, DES_BANCA_EJECUTIVO, DES_SEGMENTO_EJECUTIVO,
        DES_MODULO
    )
    SELECT
        X.FECHA_PROCESO, X.COD_MODULO, X.COD_CONVENIO, X.NUM_CUENTA_BT, X.COD_OPERACION,
        X.COD_EJECUTIVO, X.COD_TIPO_OPERACION, X.ID_OPERACION_CIERRE,
        X.TOTAL_MTO_SALDO_MO, X.TOTAL_MTO_SALDO_MN, X.TOTAL_MTO_SALDO_ME,
        X.TOTAL_AVG_SALDO_MO, X.TOTAL_AVG_SALDO_MN, X.TOTAL_AVG_SALDO_ME,
        X.TOTAL_MTO_SALDO_X_TASA_MO, X.TOTAL_MTO_SALDO_X_TASA_MN, X.TOTAL_MTO_SALDO_X_TASA_ME,
        X.TOTAL_MTO_SALDO_X_TASA_COF_MO, X.TOTAL_MTO_SALDO_X_TASA_COF_MN, X.TOTAL_MTO_SALDO_X_TASA_COF_ME,
        X.TOTAL_MTO_VENCIDO_MO, X.TOTAL_MTO_VENCIDO_MN,
        X.TOTAL_MTO_REFINANCIADO_MO, X.TOTAL_MTO_REFINANCIADO_MN,
        X.TOTAL_MTO_JUDICIAL_MO, X.TOTAL_MTO_JUDICIAL_MN,
        X.TOTAL_MTO_PROVISIONES,
        BE.NUM_BANCA, BE.NUM_SEGMENTO,
        OPM.DES_TIPO, OPM.DES_BANCA, OPM.DES_BANCA_CLASIFICACION, OPM.DES_BANCA_EJECUTIVO, OPM.DES_SEGMENTO_EJECUTIVO,
        M.NOM_MODULO
    FROM (
        SELECT
            SAL.FECHA_PROCESO, SAL.COD_MODULO, BO.COD_CONVENIO, SAL.NUM_CUENTA_BT, SAL.COD_OPERACION,
            SAL.COD_EJECUTIVO, SAL.COD_TIPO_OPERACION, SAL.ID_OPERACION_CIERRE,
            SUM(SAL.TOTAL_MTO_SALDO_MN)                                                                   AS TOTAL_MTO_SALDO_MO,
            SUM(CASE WHEN SAL.COD_MONEDA = 1 THEN SAL.TOTAL_MTO_SALDO_MN ELSE 0 END)                      AS TOTAL_MTO_SALDO_MN,
            SUM(CASE WHEN SAL.COD_MONEDA = 2 THEN SAL.TOTAL_MTO_SALDO_ME ELSE 0 END)                      AS TOTAL_MTO_SALDO_ME,
            SUM(SAL.TOTAL_AVG_SALDO_MN)                                                                   AS TOTAL_AVG_SALDO_MO,
            SUM(CASE WHEN SAL.COD_MONEDA = 1 THEN SAL.TOTAL_AVG_SALDO_MN ELSE 0 END)                      AS TOTAL_AVG_SALDO_MN,
            SUM(CASE WHEN SAL.COD_MONEDA = 2 THEN SAL.TOTAL_AVG_SALDO_ME ELSE 0 END)                      AS TOTAL_AVG_SALDO_ME,
            SUM(SAL.TOTAL_MTO_SALDO_MN * SAL.PCT_TASA)                                                    AS TOTAL_MTO_SALDO_X_TASA_MO,
            SUM(CASE WHEN SAL.COD_MONEDA = 1 THEN SAL.TOTAL_MTO_SALDO_MN * SAL.PCT_TASA ELSE 0 END)       AS TOTAL_MTO_SALDO_X_TASA_MN,
            SUM(CASE WHEN SAL.COD_MONEDA = 2 THEN SAL.TOTAL_MTO_SALDO_ME * SAL.PCT_TASA ELSE 0 END)       AS TOTAL_MTO_SALDO_X_TASA_ME,
            SUM(SAL.TOTAL_MTO_SALDO_MN * BO.PCT_TASA_COF)                                                 AS TOTAL_MTO_SALDO_X_TASA_COF_MO,
            SUM(CASE WHEN SAL.COD_MONEDA = 1 THEN SAL.TOTAL_MTO_SALDO_MN * BO.PCT_TASA_COF ELSE 0 END)    AS TOTAL_MTO_SALDO_X_TASA_COF_MN,
            SUM(CASE WHEN SAL.COD_MONEDA = 2 THEN SAL.TOTAL_MTO_SALDO_ME * BO.PCT_TASA_COF ELSE 0 END)    AS TOTAL_MTO_SALDO_X_TASA_COF_ME,
            SUM(SAL.TOTAL_MTO_SALDO_VENCIDO_MN)                                                           AS TOTAL_MTO_VENCIDO_MO,
            SUM(CASE WHEN SAL.COD_MONEDA = 1 THEN SAL.TOTAL_MTO_SALDO_VENCIDO_MN ELSE 0 END)              AS TOTAL_MTO_VENCIDO_MN,
            SUM(SAL.TOTAL_MTO_SALDO_REFINANCIADO_MN)                                                      AS TOTAL_MTO_REFINANCIADO_MO,
            SUM(CASE WHEN SAL.COD_MONEDA = 1 THEN SAL.TOTAL_MTO_SALDO_REFINANCIADO_MN ELSE 0 END)         AS TOTAL_MTO_REFINANCIADO_MN,
            SUM(SAL.TOTAL_MTO_SALDO_JUDICIAL_MN)                                                          AS TOTAL_MTO_JUDICIAL_MO,
            SUM(CASE WHEN SAL.COD_MONEDA = 1 THEN SAL.TOTAL_MTO_SALDO_JUDICIAL_MN ELSE 0 END)             AS TOTAL_MTO_JUDICIAL_MN,
            SUM(SAL.TOTAL_MTO_PREVISIONES)                                                                AS TOTAL_MTO_PROVISIONES
        FROM BDS_SALDOS_OPERATIVOS SAL
        LEFT JOIN (   -- [C03] una fila por operación activa  -- VALIDAR (V3)
            SELECT ID_OPERACION,
                   MAX(COD_CONVENIO) AS COD_CONVENIO,
                   MAX(PCT_TASA_COF) AS PCT_TASA_COF
            FROM BDS_OPERACIONES
            WHERE IND_ACTIVO = 1
            GROUP BY ID_OPERACION
        ) BO ON BO.ID_OPERACION = SAL.ID_OPERACION_CIERRE
        WHERE SAL.FECHA_PROCESO = V_FECHA_CIERRE
        GROUP BY SAL.FECHA_PROCESO, SAL.COD_MODULO, BO.COD_CONVENIO, SAL.NUM_CUENTA_BT,
                 SAL.COD_OPERACION, SAL.COD_EJECUTIVO, SAL.COD_TIPO_OPERACION, SAL.ID_OPERACION_CIERRE
    ) X
    LEFT JOIN (   -- antes UPDATE 1: banca / segmento del ejecutivo al cierre
        SELECT COD_EJECUTIVO,
               MAX(NUM_BANCA)    AS NUM_BANCA,
               MAX(NUM_SEGMENTO) AS NUM_SEGMENTO
        FROM BDS_EJECUTIVOS
        WHERE FECHA_PROCESO = V_FECHA_CIERRE
        GROUP BY COD_EJECUTIVO
    ) BE ON BE.COD_EJECUTIVO = X.COD_EJECUTIVO
    LEFT JOIN (   -- antes UPDATE 2: parámetros MFB (una fila por módulo/banca/segmento)
        SELECT CAST(COD_MODULO AS SIGNED)             AS COD_MODULO,
               CAST(COD_BANCA_EJECUTIVO AS SIGNED)    AS COD_BANCA_EJECUTIVO,
               CAST(COD_SEGMENTO_EJECUTIVO AS SIGNED) AS COD_SEGMENTO_EJECUTIVO,
               MAX(DES_TIPO)                 AS DES_TIPO,
               MAX(DES_BANCA)                AS DES_BANCA,
               MAX(DES_BANCA_CLASIFICACION)  AS DES_BANCA_CLASIFICACION,
               MAX(DES_BANCA_EJECUTIVO)      AS DES_BANCA_EJECUTIVO,
               MAX(DES_SEGEMENTO_EJECUTIVO)  AS DES_SEGMENTO_EJECUTIVO
        FROM ODS_PARAMETROS_MFB
        GROUP BY CAST(COD_MODULO AS SIGNED),
                 CAST(COD_BANCA_EJECUTIVO AS SIGNED),
                 CAST(COD_SEGMENTO_EJECUTIVO AS SIGNED)
    ) OPM ON  OPM.COD_MODULO             = X.COD_MODULO
          AND OPM.COD_BANCA_EJECUTIVO    = BE.NUM_BANCA
          AND OPM.COD_SEGMENTO_EJECUTIVO = BE.NUM_SEGMENTO
    LEFT JOIN (   -- antes UPDATE 3: nombre del módulo
        SELECT COD_MODULO, MAX(NOM_MODULO) AS NOM_MODULO
        FROM BDS_MODULO
        GROUP BY COD_MODULO
    ) M ON M.COD_MODULO = X.COD_MODULO;

    V_FILAS_CU = ROW_COUNT();

    /* ==================================================================================
       PASO 2. CU_SALDOS_OPERATIVOS_RESULTADO_BANCO_CONSOLIDADO (cierre del mes)
       ================================================================================== */
    DELETE FROM CU_SALDOS_OPERATIVOS_RESULTADO_BANCO_CONSOLIDADO
    WHERE FECHA_PROCESO = V_FECHA_CIERRE;

    INSERT INTO CU_SALDOS_OPERATIVOS_RESULTADO_BANCO_CONSOLIDADO (
        FECHA_PROCESO, DES_CATEGORIA, DES_CATEGORIA_2, DES_TIPO, COD_MODULO, DES_MODULO,
        DES_BANCA, DES_BANCA_CLASIFICACION, DES_BANCA_EJECUTIVO, DES_SEGMENTO_EJECUTIVO, NUM_CUENTA_BT,
        nivel_00, nivel_01, nivel_02, nivel_03, nivel_04, nivel_05,
        Saldo_MO, Saldo_MN, Saldo_ME,
        Saldo_prm_MO, Saldo_prm_MN, Saldo_prm_ME,
        TOTAL_MTO_SALDO_X_TASA_MO, TOTAL_MTO_SALDO_X_TASA_MN, TOTAL_MTO_SALDO_X_TASA_ME,
        TOTAL_MTO_SALDO_X_TASA_COF_MO, TOTAL_MTO_SALDO_X_TASA_COF_MN, TOTAL_MTO_SALDO_X_TASA_COF_ME,
        TOTAL_MTO_VENCIDO_MO, TOTAL_MTO_VENCIDO_MN,
        TOTAL_MTO_REFINANCIADO_MO, TOTAL_MTO_REFINANCIADO_MN,
        TOTAL_MTO_JUDICIAL_MO, TOTAL_MTO_JUDICIAL_MN,
        TOTAL_MTO_PROVISIONES
    )
    /* ----------------------------------------------------------------------------------
       2A. CARTERA + FONDEO  (desde CU, una regla por cada rama del UNION ALL original)
       ---------------------------------------------------------------------------------- */
    SELECT
        T.FECHA_PROCESO, '' AS DES_CATEGORIA, '' AS DES_CATEGORIA_2,
        T.DES_TIPO, T.COD_MODULO, T.DES_MODULO, T.DES_BANCA, T.DES_BANCA_CLASIFICACION,
        T.DES_BANCA_EJECUTIVO, T.DES_SEGMENTO_EJECUTIVO, T.NUM_CUENTA_BT,
        T.NIVEL_00, T.NIVEL_01, T.NIVEL_02, T.NIVEL_03, T.NIVEL_04, T.NIVEL_05,
        SUM(T.TOTAL_MTO_SALDO_MO * T.SIGNO),            SUM(T.TOTAL_MTO_SALDO_MN * T.SIGNO),            SUM(T.TOTAL_MTO_SALDO_ME * T.SIGNO),
        SUM(T.TOTAL_AVG_SALDO_MO * T.SIGNO),            SUM(T.TOTAL_AVG_SALDO_MN * T.SIGNO),            SUM(T.TOTAL_AVG_SALDO_ME * T.SIGNO),
        SUM(T.TOTAL_MTO_SALDO_X_TASA_MO * T.SIGNO),     SUM(T.TOTAL_MTO_SALDO_X_TASA_MN * T.SIGNO),     SUM(T.TOTAL_MTO_SALDO_X_TASA_ME * T.SIGNO),
        SUM(T.TOTAL_MTO_SALDO_X_TASA_COF_MO * T.SIGNO), SUM(T.TOTAL_MTO_SALDO_X_TASA_COF_MN * T.SIGNO), SUM(T.TOTAL_MTO_SALDO_X_TASA_COF_ME * T.SIGNO),
        SUM(T.TOTAL_MTO_VENCIDO_MO * T.SIGNO),          SUM(T.TOTAL_MTO_VENCIDO_MN * T.SIGNO),
        SUM(T.TOTAL_MTO_REFINANCIADO_MO * T.SIGNO),     SUM(T.TOTAL_MTO_REFINANCIADO_MN * T.SIGNO),
        SUM(T.TOTAL_MTO_JUDICIAL_MO * T.SIGNO),         SUM(T.TOTAL_MTO_JUDICIAL_MN * T.SIGNO),
        SUM(T.TOTAL_MTO_PROVISIONES)                    -- provisiones sin signo (igual que en el original)
    FROM (
        SELECT
            B.*,
            R.REGLA,
            R.SIGNO,
            'Rendimiento y Costos de Fondeo - Consolidado' AS NIVEL_00,
            R.N01 AS NIVEL_01,
            R.N02 AS NIVEL_02,
            CASE R.REGLA
                WHEN 4  THEN CASE WHEN B.COD_MODULO IN (101,140) THEN 'Banca Personal - con MVV' ELSE 'Banca Personal - sin MVV' END
                WHEN 24 THEN CASE WHEN B.COD_MODULO = 29 THEN 'Carta Fianza'
                                  WHEN B.COD_MODULO = 2  THEN 'Carta Credito' END
                ELSE R.N03
            END AS NIVEL_03,
            CASE R.REGLA
                WHEN 1  THEN CASE WHEN B.COD_CONVENIO IN ('1035558','1312109','1363540') THEN 'PNP' ELSE 'Resto convenios' END
                WHEN 4  THEN CASE WHEN B.COD_MODULO = 65 THEN 'Tarjeta de Crédito'
                                  WHEN B.COD_MODULO IN (101,140) THEN 'Mivivienda'
                                  WHEN B.COD_MODULO = 103 THEN 'Préstamo Personal'
                                  ELSE '' END
                WHEN 7  THEN CASE WHEN B.ES_RECUP_LIMA = 1 THEN 'Empresas Lima' ELSE 'Empresas Provincia' END
                WHEN 8  THEN CASE WHEN B.COD_MODULO = 102 THEN 'Hipotecario'
                                  WHEN B.COD_MODULO IN (101,140) THEN 'Mivivienda'
                                  WHEN B.COD_MODULO = 103 THEN 'Préstamo Personal' END
                WHEN 9  THEN CASE WHEN B.COD_TIPO_OPERACION IN ('1','2') THEN 'DPF' ELSE 'DPO' END
                WHEN 10 THEN CASE WHEN B.COD_TIPO_OPERACION = '1' THEN 'Tradicional'
                                  WHEN B.COD_TIPO_OPERACION = '7' THEN 'Experiencia'
                                  WHEN B.COD_TIPO_OPERACION = '8' THEN 'Rolando'
                                  ELSE 'Otro' END
                WHEN 24 THEN CASE WHEN B.COD_MODULO = 29 AND B.NUM_BANCA IN (3,7) THEN 'Banca Empresas'
                                  WHEN B.COD_MODULO = 29 AND B.NUM_BANCA IN (6)   THEN 'Recuperaciones'
                                  WHEN B.COD_MODULO = 2                           THEN 'Banca Empresas' END
                ELSE R.N04
            END AS NIVEL_04,
            CASE R.REGLA
                WHEN 5 THEN B.DES_BANCA_CLASIFICACION
                WHEN 6 THEN CASE WHEN B.COD_MODULO = 111 THEN 'Capital de Trabajo'
                                 WHEN B.COD_MODULO IN (112,113,114) THEN 'Comercio Exterior'
                                 WHEN B.COD_MODULO = 115 THEN 'Mediano Plazo'
                                 WHEN B.COD_MODULO = 139 THEN 'Confirming'
                                 WHEN B.COD_MODULO = 149 THEN 'Factoring'
                                 WHEN B.COD_MODULO = 36  THEN 'Leasing'
                                 WHEN B.COD_MODULO = 71  THEN 'Descuento de letras'
                                 WHEN B.COD_MODULO = 49  THEN 'Sobregiro'
                                 ELSE NULL END
                ELSE R.N05
            END AS NIVEL_05
        FROM (
            /* ---------- Base: CU del cierre + cruces deduplicados + flags de cada regla ---------- */
            SELECT
                SAL.FECHA_PROCESO, SAL.DES_TIPO, SAL.COD_MODULO, SAL.DES_MODULO, SAL.DES_BANCA,
                SAL.DES_BANCA_CLASIFICACION, SAL.DES_BANCA_EJECUTIVO, SAL.DES_SEGMENTO_EJECUTIVO,
                SAL.NUM_CUENTA_BT, SAL.COD_CONVENIO, SAL.COD_TIPO_OPERACION,
                SAL.COD_EJECUTIVO, SAL.NUM_SEGMENTO, SAL.NUM_BANCA,
                SAL.TOTAL_MTO_SALDO_MO, SAL.TOTAL_MTO_SALDO_MN, SAL.TOTAL_MTO_SALDO_ME,
                SAL.TOTAL_AVG_SALDO_MO, SAL.TOTAL_AVG_SALDO_MN, SAL.TOTAL_AVG_SALDO_ME,
                SAL.TOTAL_MTO_SALDO_X_TASA_MO, SAL.TOTAL_MTO_SALDO_X_TASA_MN, SAL.TOTAL_MTO_SALDO_X_TASA_ME,
                SAL.TOTAL_MTO_SALDO_X_TASA_COF_MO, SAL.TOTAL_MTO_SALDO_X_TASA_COF_MN, SAL.TOTAL_MTO_SALDO_X_TASA_COF_ME,
                SAL.TOTAL_MTO_VENCIDO_MO, SAL.TOTAL_MTO_VENCIDO_MN,
                SAL.TOTAL_MTO_REFINANCIADO_MO, SAL.TOTAL_MTO_REFINANCIADO_MN,
                SAL.TOTAL_MTO_JUDICIAL_MO, SAL.TOTAL_MTO_JUDICIAL_MN,
                SAL.TOTAL_MTO_PROVISIONES,

                CASE WHEN SAL.NUM_CUENTA_BT IN ('1023843','1038296','1041708','1042206','1050390','1060546','1062082','1063574','1066194',
                                                '1066238','1066492','1066912','1067242','1069847','1070807','1109604','1116790','1116942','1150564',
                                                '1170063','1180329','1232519','1236106','1244020','1244207','1257904','1267374','1267957','1289536',
                                                '1298095','1298139','1304319','1309665','1314251','1260016','1325996','1023187','1295889')
                     THEN 1 ELSE 0 END AS ES_RECUP_LIMA,
                CASE WHEN SAL.NUM_CUENTA_BT IN ('1170520','1172742','1183205','1185292','1185293','1240708','1245851','1298848','1299562','1343299')
                     THEN 1 ELSE 0 END AS ES_RECUP_PROV,
                CASE WHEN SAL.NUM_CUENTA_BT IN (1465362,1234715,1022971,1422706,1445934,1061862,1055826,
                                                1446646,1023241,1445928,1066639,1411239,1444793)
                     THEN 1 ELSE 0 END AS ES_CTA_TESORERIA,
                CASE WHEN S.NUM_CUENTA_BT IS NOT NULL THEN 1 ELSE 0 END AS EXISTE_CUENTA,   -- emula el INNER JOIN ODS_CUENTA
                S.COD_CLAS_INTERNA,
                COALESCE(OMP.ES_NEGOCIO_4, 0) AS ES_NEGOCIO_4,
                CASE WHEN BSC.ID_OPERACION IS NOT NULL THEN 1 ELSE 0 END AS TIENE_RUBRO_22_1
            FROM CU_SALDOS_OPERATIVOS_RESULTADO_BANCO SAL
            LEFT JOIN (   -- [C03] una fila por cuenta  -- VALIDAR (V3)
                SELECT NUM_CUENTA_BT, MAX(COD_CLAS_INTERNA) AS COD_CLAS_INTERNA
                FROM ODS_CUENTA
                GROUP BY NUM_CUENTA_BT
            ) S ON S.NUM_CUENTA_BT = SAL.NUM_CUENTA_BT
            LEFT JOIN (   -- [C03] una fila por módulo/tipo de operación
                SELECT COD_MODULO, COD_TIPO_OPERACION,
                       MAX(CASE WHEN TIP_NEGOCIO = '4' THEN 1 ELSE 0 END) AS ES_NEGOCIO_4
                FROM ODS_MODULO_PRODUCTO
                GROUP BY COD_MODULO, COD_TIPO_OPERACION
            ) OMP ON OMP.COD_MODULO = SAL.COD_MODULO AND OMP.COD_TIPO_OPERACION = SAL.COD_TIPO_OPERACION
            LEFT JOIN (   -- [C03] regla 23: antes INNER JOIN BDS_SALDOS_CIERRE, que repetía la fila por cada rubro 22_1
                SELECT DISTINCT ID_OPERACION
                FROM BDS_SALDOS_CIERRE
                WHERE FECHA_PROCESO = V_FECHA_CIERRE
                  AND COD_RUBRO LIKE '22_1%'
            ) BSC ON BSC.ID_OPERACION = SAL.ID_OPERACION_CIERRE
            WHERE SAL.FECHA_PROCESO = V_FECHA_CIERRE
        ) B
        JOIN (
            /* ---------- Tabla de reglas: una fila = una rama del UNION ALL original ----------
               REGLA | SIGNO | nivel_01 | nivel_02 | nivel_03 | nivel_04 | nivel_05
               ('' en un nivel dinámico = se calcula en el CASE de arriba)                   */
            SELECT  1 AS REGLA,  1 AS SIGNO, 'Activos Promedio - Consolidado' AS N01, 'Cartera' AS N02, 'Convenios' AS N03, '' AS N04, '' AS N05
            UNION ALL SELECT  2,  1, 'Activos Promedio - Consolidado', 'Cartera',        'Banca Personal - sin MVV', 'Hipotecario',  ''
            UNION ALL SELECT  3,  1, 'Activos Promedio - Consolidado', 'Cartera',        'Banca Personal - sin MVV', 'Inmobiliario', ''
            UNION ALL SELECT  4,  1, 'Activos Promedio - Consolidado', 'Cartera',        '',                         '',             ''
            UNION ALL SELECT  5,  1, 'Activos Promedio - Consolidado', 'Cartera',        'Banca Empresa',            'Segmentos Empresas', ''
            UNION ALL SELECT  6,  1, 'Activos Promedio - Consolidado', 'Cartera',        'Banca Empresa',            'Productos Empresas', ''
            UNION ALL SELECT  7,  1, 'Activos Promedio - Consolidado', 'Recuperaciones', 'Recuperaciones',           '',             ''
            UNION ALL SELECT  8,  1, 'Activos Promedio - Consolidado', 'Recuperaciones', 'Cobranzas',                '',             ''
            -- PENDIENTE (V1-b): rama faltante entre 'Otros Ingresos' y 'Fondeo - Personas - Plazo'
            UNION ALL SELECT  9,  1, 'Fondeo Promedio', 'Personas',          'Plazo',                    '',                         ''
            UNION ALL SELECT 10,  1, 'Fondeo Promedio', 'Personas',          'Ahorro',                   '',                         ''
            UNION ALL SELECT 11,  1, 'Fondeo Promedio', 'Personas',          'CTS',                      '',                         ''
            UNION ALL SELECT 12,  1, 'Fondeo Promedio', 'Empresas',          'Plazo',                    '',                         ''
            UNION ALL SELECT 13,  1, 'Fondeo Promedio', 'Empresas',          'Cuenta Corriente CM',      'Cuenta Corriente PJ',      ''
            UNION ALL SELECT 14, -1, 'Fondeo Promedio', 'Empresas',          'Cuenta Corriente CM',      'Reclas. Tes.a - Cta Cte',  ''
            UNION ALL SELECT 15,  1, 'Fondeo Promedio', 'Tesoreria',         'Institucional',            '',                         ''
            UNION ALL SELECT 16,  1, 'Fondeo Promedio', 'Tesoreria',         'AFPs y Fondos Mutuos',     '',                         ''
            UNION ALL SELECT 17,  1, 'Fondeo Promedio', 'Tesoreria',         'DPF Sistema Financiero',   '',                         ''
            UNION ALL SELECT 18,  1, 'Fondeo Promedio', 'Tesoreria',         'Cuenta Corriente',         '',                         ''
            UNION ALL SELECT 19,  1, 'Fondeo Promedio', 'Otras Fuentes',     'Adeudados',                '',                         ''
            UNION ALL SELECT 20,  1, 'Fondeo Promedio', 'Otras Fuentes',     'COFIDE Mivivienda',        '',                         ''
            UNION ALL SELECT 21,  1, 'Fondeo Promedio', 'Mcdo de Capitales', 'Bonos Subordinados',       '',                         ''
            UNION ALL SELECT 22,  1, 'Fondeo Promedio', 'Mcdo de Capitales', 'Certificados Depósitos',   '',                         ''
            UNION ALL SELECT 23,  1, 'Fondeo Promedio', 'Fondos Interbancarios', '',                     '',                         ''
            UNION ALL SELECT 24,  1, 'Activos Promedio - Consolidado', 'Colocaciones Indirectas', '',    '',                         ''
        ) R
          ON 1 = CASE R.REGLA
                    -- ACTIVOS / CARTERA
                    WHEN 1  THEN B.COD_MODULO = 239                                                         -- Convenios
                    WHEN 2  THEN B.COD_MODULO = 102 AND B.COD_EJECUTIVO <> 399                             -- Hipotecario
                    WHEN 3  THEN B.DES_SEGMENTO_EJECUTIVO = 'Inmobiliario' AND B.COD_MODULO IN (116,111)  -- Inmobiliario
                    WHEN 4  THEN B.DES_BANCA = 'Banca Personal' AND B.COD_MODULO IN (65,101,103,140)      -- Banca Personal
                    WHEN 5  THEN B.DES_BANCA = 'Banca Empresa'  AND B.DES_TIPO = 'Directo'                -- Segmentos Empresas
                    WHEN 6  THEN B.DES_BANCA = 'Banca Empresa'  AND B.DES_TIPO = 'Directo'                -- Productos Empresas
                    -- ACTIVOS / RECUPERACIONES
                    WHEN 7  THEN B.ES_RECUP_LIMA = 1 OR B.ES_RECUP_PROV = 1                                -- Recuperaciones
                    WHEN 8  THEN B.COD_MODULO IN (102,101,140,103) AND B.NUM_SEGMENTO = 9                  -- Cobranzas
                    -- FONDEO / PERSONAS
                    WHEN 9  THEN B.COD_MODULO = 22  AND B.NUM_SEGMENTO = 1 AND B.NUM_BANCA = 1            -- Plazo
                    WHEN 10 THEN B.COD_MODULO = 21  AND B.NUM_SEGMENTO = 1 AND B.NUM_BANCA = 1            -- Ahorro
                    WHEN 11 THEN B.COD_MODULO = 321                                                         -- CTS
                    -- FONDEO / EMPRESAS
                    WHEN 12 THEN B.EXISTE_CUENTA = 1 AND (
                                    (B.COD_MODULO = 185 AND B.NUM_SEGMENTO IN (3,7,8) AND B.COD_CLAS_INTERNA NOT IN (14,9))
                                 OR (B.COD_MODULO = 22  AND B.NUM_SEGMENTO IN (3)))                         -- Plazo
                    WHEN 13 THEN B.COD_MODULO = 20 AND B.NUM_SEGMENTO <> 1 AND B.NUM_BANCA <> 1           -- Cta Cte PJ
                    WHEN 14 THEN B.COD_MODULO = 20 AND B.NUM_SEGMENTO <> 1 AND B.NUM_BANCA <> 1
                                 AND B.ES_CTA_TESORERIA = 1                                                 -- Reclas. (signo -1)
                    -- FONDEO / TESORERÍA
                    WHEN 15 THEN B.EXISTE_CUENTA = 1 AND (
                                    (B.COD_MODULO = 185 AND B.NUM_SEGMENTO NOT IN (3,7,8) AND B.COD_CLAS_INTERNA NOT IN (14,9))
                                 OR (B.COD_MODULO = 22  AND B.NUM_SEGMENTO IN (10)))                        -- Institucional
                    WHEN 16 THEN B.EXISTE_CUENTA = 1 AND B.COD_MODULO = 185
                                 AND B.NUM_SEGMENTO NOT IN (3,7,8) AND B.COD_CLAS_INTERNA = 14             -- AFPs y FFMM
                    WHEN 17 THEN B.EXISTE_CUENTA = 1 AND B.COD_MODULO = 185
                                 AND B.NUM_SEGMENTO NOT IN (3,7,8) AND B.COD_CLAS_INTERNA = 9              -- DPF Sist. Fin.
                    WHEN 18 THEN B.COD_MODULO = 20 AND B.NUM_SEGMENTO <> 1 AND B.NUM_BANCA <> 1
                                 AND B.ES_CTA_TESORERIA = 1                                                 -- Cuenta Corriente
                    -- FONDEO / OTRAS FUENTES
                    WHEN 19 THEN B.EXISTE_CUENTA = 1 AND B.COD_MODULO IN (162,155)                        -- Adeudados
                    WHEN 20 THEN B.EXISTE_CUENTA = 1 AND B.COD_MODULO = 120
                                 AND B.NUM_SEGMENTO = 10 AND B.NUM_BANCA = 3                                -- COFIDE MVV
                    -- FONDEO / MERCADO DE CAPITALES
                    WHEN 21 THEN B.COD_MODULO = 120 AND B.ES_NEGOCIO_4 = 1                                -- Bonos Subord.
                    WHEN 22 THEN B.COD_MODULO = 22 AND B.NUM_SEGMENTO IN (5,8) AND B.NUM_BANCA IN (7,3)   -- CDs
                    -- FONDEO / FONDOS INTERBANCARIOS
                    WHEN 23 THEN B.COD_MODULO = 185 AND B.TIENE_RUBRO_22_1 = 1                            -- Fondos Interb.
                    -- ACTIVOS / COLOCACIONES INDIRECTAS (20261021 Fabrizio)
                    WHEN 24 THEN B.COD_MODULO IN (2,29)                                                    -- Col. Indirectas
                    ELSE 0
                 END
    ) T
    GROUP BY T.REGLA, T.FECHA_PROCESO, T.DES_TIPO, T.COD_MODULO, T.DES_MODULO, T.DES_BANCA,
             T.DES_BANCA_CLASIFICACION, T.DES_BANCA_EJECUTIVO, T.DES_SEGMENTO_EJECUTIVO, T.NUM_CUENTA_BT,
             T.NIVEL_00, T.NIVEL_01, T.NIVEL_02, T.NIVEL_03, T.NIVEL_04, T.NIVEL_05

    UNION ALL

    /* ----------------------------------------------------------------------------------
       2B. INVERSIONES / FILIALES / LIQUIDEZ  (fuentes diarias)  [C05]
           Saldo    = valor del día de cierre
           Promedio = AVG de los días con dato en el mes (= SUM()/COUNT(*) de la ventana original)
       ---------------------------------------------------------------------------------- */
    SELECT
        V_FECHA_CIERRE, '', '', '', '', '', '', '', '', '', '',     -- VALIDAR (V4)
        'Rendimiento y Costos de Fondeo - Consolidado', 'Activos Promedio - Consolidado',
        D.N02, D.N03, D.N04, '',
        SUM(CASE WHEN D.FECHA_PROCESO = V_FECHA_CIERRE THEN D.MTO_SALDO_MO ELSE 0 END),
        SUM(CASE WHEN D.FECHA_PROCESO = V_FECHA_CIERRE THEN D.MTO_SALDO_MN ELSE 0 END),
        SUM(CASE WHEN D.FECHA_PROCESO = V_FECHA_CIERRE THEN D.MTO_SALDO_ME ELSE 0 END),
        CAST(AVG(D.MTO_SALDO_MO) AS DECIMAL(17,4)),
        CAST(AVG(D.MTO_SALDO_MN) AS DECIMAL(17,4)),
        CAST(AVG(D.MTO_SALDO_ME) AS DECIMAL(17,4)),
        NULL, NULL, NULL,          -- tasa
        NULL, NULL, NULL,          -- tasa COF
        NULL, NULL,                -- vencido
        NULL, NULL,                -- refinanciado
        NULL, NULL,                -- judicial
        NULL                       -- provisiones
    FROM (
        -- Inversiones - CDs
        SELECT 1 AS ORDEN, 'Inversiones' AS N02, 'CDs' AS N03, '' AS N04, SCC.FECHA_PROCESO,
               SUM(SCC.TL_NOMINALACUMULADODIA) AS MTO_SALDO_MO,
               SUM(SCC.TL_NOMINALACUMULADODIA) AS MTO_SALDO_MN,
               0                               AS MTO_SALDO_ME
        FROM STG_CARTERA_CONSOLIDADA SCC
        WHERE SCC.TL_CODFAMILIA = '551'
          AND SCC.FECHA_PROCESO BETWEEN V_FEC_INI AND V_FECHA_CIERRE
        GROUP BY SCC.FECHA_PROCESO

        UNION ALL
        -- Inversiones - CDs IFIs
        SELECT 2, 'Inversiones', 'CDs IFIs', '', SCC.FECHA_PROCESO,
               SUM(SCC.TL_NOMINALACUMULADODIA), SUM(SCC.TL_NOMINALACUMULADODIA), 0
        FROM STG_CARTERA_CONSOLIDADA SCC
        WHERE SCC.TL_CODFAMILIA = 'PENDIENTE'          -- PENDIENTE (V1-a): filtro no visible en las capturas
          AND SCC.FECHA_PROCESO BETWEEN V_FEC_INI AND V_FECHA_CIERRE
        GROUP BY SCC.FECHA_PROCESO

        UNION ALL
        -- Inversiones - Bonos
        SELECT 3, 'Inversiones', 'Bonos', '', SCC.FECHA_PROCESO,
               SUM(SCC.TL_NOMINALACUMULADODIA), SUM(SCC.TL_NOMINALACUMULADODIA), 0
        FROM STG_CARTERA_CONSOLIDADA SCC
        WHERE SCC.TL_CODFAMILIA = '100'
          AND SCC.FECHA_PROCESO BETWEEN V_FEC_INI AND V_FECHA_CIERRE
        GROUP BY SCC.FECHA_PROCESO

        UNION ALL
        -- Filiales - Panamá
        SELECT 4, 'Filiales', 'Panamá', '', BSDC.FECHA_PROCESO,
               SUM(BSDC.MTO_SALDO_MN),
               SUM(CASE WHEN B.COD_MONEDA = 1 THEN BSDC.MTO_SALDO_MN ELSE 0 END),
               SUM(CASE WHEN B.COD_MONEDA = 2 THEN BSDC.MTO_SALDO_ME ELSE 0 END)
        FROM BDS_SALDOS_DIARIOS_CONSOLIDADOS BSDC
        LEFT JOIN (SELECT COD_RUBRO, MAX(COD_MONEDA) AS COD_MONEDA
                   FROM BDS_CONSOLIDADO_SBS_BT GROUP BY COD_RUBRO) B
               ON B.COD_RUBRO = BSDC.COD_RUBRO
        WHERE BSDC.COD_RUBRO = '1124020000001001'
          AND BSDC.FECHA_PROCESO BETWEEN V_FEC_INI AND V_FECHA_CIERRE
        GROUP BY BSDC.FECHA_PROCESO

        UNION ALL
        -- Liquidez (Encaje, BCRP) - Bcr Depósitos - Cuenta Cte Ordinaria
        SELECT 5, 'Liquidez (Encaje, BCRP)', 'Bcr - Depósitos', 'Bcr -Cuenta Cte Ordinaria', BSDC.FECHA_PROCESO,
               SUM(BSDC.MTO_SALDO_MN),
               SUM(CASE WHEN B.COD_MONEDA = 1 THEN BSDC.MTO_SALDO_MN ELSE 0 END),
               SUM(CASE WHEN B.COD_MONEDA = 2 THEN BSDC.MTO_SALDO_ME ELSE 0 END)
        FROM BDS_SALDOS_CIERRE BSDC
        LEFT JOIN (SELECT COD_RUBRO, MAX(COD_MONEDA) AS COD_MONEDA
                   FROM BDS_CONSOLIDADO_SBS_BT GROUP BY COD_RUBRO) B
               ON B.COD_RUBRO = BSDC.COD_RUBRO
        WHERE (   BSDC.COD_RUBRO LIKE '11_1%' OR BSDC.COD_RUBRO LIKE '11_2%' OR BSDC.COD_RUBRO LIKE '11_3%'
               OR BSDC.COD_RUBRO LIKE '11_4%' OR BSDC.COD_RUBRO LIKE '11_5%' OR BSDC.COD_RUBRO LIKE '27_2%')
          AND BSDC.FECHA_PROCESO BETWEEN V_FEC_INI AND V_FECHA_CIERRE
        GROUP BY BSDC.FECHA_PROCESO

        UNION ALL
        -- Liquidez (Encaje, BCRP) - Fondos Interbancarios - Otros Ingresos
        SELECT 6, 'Liquidez (Encaje, BCRP)', 'Fondos Interbancarios', 'Otros Ingresos', BSDC.FECHA_PROCESO,
               SUM(BSDC.MTO_SALDO_MN),
               SUM(CASE WHEN B.COD_MONEDA = 1 THEN BSDC.MTO_SALDO_MN ELSE 0 END),
               SUM(CASE WHEN B.COD_MONEDA = 2 THEN BSDC.MTO_SALDO_ME ELSE 0 END)
        FROM BDS_SALDOS_CIERRE BSDC
        LEFT JOIN (SELECT COD_RUBRO, MAX(COD_MONEDA) AS COD_MONEDA
                   FROM BDS_CONSOLIDADO_SBS_BT GROUP BY COD_RUBRO) B
               ON B.COD_RUBRO = BSDC.COD_RUBRO
        WHERE BSDC.COD_MODULO = 183
          AND BSDC.COD_RUBRO LIKE '12_1%'
          AND BSDC.FECHA_PROCESO BETWEEN V_FEC_INI AND V_FECHA_CIERRE
        GROUP BY BSDC.FECHA_PROCESO
    ) D
    GROUP BY D.ORDEN, D.N02, D.N03, D.N04;

    V_FILAS_CONS = ROW_COUNT();

    COMMIT;

    /* ==================================================================================
       LOG DE FIN
       ================================================================================== */
    IF V_FILAS_CU = 0 OR V_FILAS_CONS = 0 THEN
        V_MSG = CONCAT('Cierre ', V_FECHA_CIERRE,
                       ': filas CU = ', V_FILAS_CU,
                       ', filas CONSOLIDADO = ', V_FILAS_CONS);
    END IF;

    UPDATE ctl_log_proceso
       SET estado           = CASE WHEN V_MSG IS NULL THEN 'TERMINADO' ELSE 'WARNING' END,
           fec_termino      = NOW(6),
           filas_insertadas = V_FILAS_CU + V_FILAS_CONS,
           msg_error        = V_MSG
     WHERE id_log = V_ID_LOG;

EXCEPTION
    WHEN OTHERS THEN
        ROLLBACK;
        UPDATE ctl_log_proceso
           SET estado      = 'ERROR',
               fec_termino = NOW(6),
               msg_error   = CONCAT('Error procesando cierre ', V_FECHA_CIERRE, ' (ver detalle en el cliente / logs del motor)')
         WHERE id_log = V_ID_LOG;
        RAISE;
END //

DELIMITER ;

/* ------------------------------------------------------------------------------------
   Ejecución
   ------------------------------------------------------------------------------------
   CALL SP_CU_SALDOS_OPERATIVOS_RESULTADO_BANCO('2026-10-31');

   Conciliación sugerida contra el script original (mismo cierre, por niveles):
   SELECT nivel_01, nivel_02, nivel_03, nivel_04, nivel_05,
          SUM(Saldo_MN), SUM(Saldo_prm_MN), COUNT(*)
   FROM CU_SALDOS_OPERATIVOS_RESULTADO_BANCO_CONSOLIDADO
   WHERE FECHA_PROCESO = '2026-10-31'
   GROUP BY 1,2,3,4,5 ORDER BY 1,2,3,4,5;
   ------------------------------------------------------------------------------------ */
