/* =====================================================================================
   PROCEDIMIENTO : SP_CU_RESULTADO_BANCO_CONSOLIDADO
   MOTOR         : SingleStore
   PARÁMETRO     : P_FECHA_PROCESO
                     - una fecha cualquiera del mes -> procesa ese cierre (LAST_DAY)
                     - NULL                         -> recarga completa (todos los cierres)

   QUÉ HACE
   -------------------------------------------------------------------------------------
   Une en CU_RESULTADO_BANCO_CONSOLIDADO:
     1) CU_RESULTADO_BANCO_CONSOLIDADO_PLANEAMIENTO (saldos de cierre y variación mensual, la genera Pablo)
     2) CU_SALDOS_OPERATIVOS_RESULTADO_BANCO_CONSOLIDADO (saldos operativos y promedios,
        la genera SP_CU_SALDOS_OPERATIVOS_RESULTADO_BANCO)
   y marca Flag_fecha_maxima = 1 en el último cierre cargado.

   ORDEN DE EJECUCIÓN
     1. CALL SP_CU_SALDOS_OPERATIVOS_RESULTADO_BANCO('<fecha>');
     2. (proceso de Planeamiento del mismo cierre)
     3. CALL SP_CU_RESULTADO_BANCO_CONSOLIDADO('<fecha>');

   CAMBIOS RESPECTO AL SCRIPT ORIGINAL
   -------------------------------------------------------------------------------------
   [C01] DELETE + INSERT del cierre, en vez de CREATE TABLE con toda la historia.
         La tabla debe existir (créala una vez con el CREATE TABLE ... SELECT original).
   [C02] Flag_fecha_maxima se calcula con MAX(FECHA_PROCESO). Antes estaba fijo en
         '2026-11-30'.
   [C03] El flag solo se modifica en las filas que cambian (las del cierre anterior y las
         del nuevo), no en toda la tabla.
   [C04] La rama de saldos operativos también filtra por cierre de mes (antes no tenía WHERE).
   [C05] Log en ctl_log_proceso + transacción + manejo de excepciones.
   ===================================================================================== */

DELIMITER //

CREATE OR REPLACE PROCEDURE SP_CU_RESULTADO_BANCO_CONSOLIDADO(P_FECHA_PROCESO DATE)
AS
DECLARE
    V_FECHA_CIERRE  DATE = NULL;
    V_FECHA_MAX     DATE;
    V_FILAS         BIGINT = 0;
    V_ID_LOG        BIGINT;
    V_MSG           LONGTEXT = NULL;
BEGIN
    IF P_FECHA_PROCESO IS NOT NULL THEN
        V_FECHA_CIERRE = LAST_DAY(P_FECHA_PROCESO);
    END IF;

    INSERT INTO ctl_log_proceso (nom_proceso, tabla_origen, tabla_destino, fec_inicio, estado)
    VALUES ('DATAHUB_CU_RESULTADO_BANCO_CONSOLIDADO',
            'CU_RESULTADO_BANCO_CONSOLIDADO_PLANEAMIENTO, CU_SALDOS_OPERATIVOS_RESULTADO_BANCO_CONSOLIDADO',
            'CU_RESULTADO_BANCO_CONSOLIDADO',
            NOW(6), 'EJECUTANDO');
    V_ID_LOG = LAST_INSERT_ID();

    START TRANSACTION;

    /* ---------------------------------------------------------------------------
       1. Limpieza del cierre (o de toda la tabla si P_FECHA_PROCESO es NULL)
       --------------------------------------------------------------------------- */
    IF V_FECHA_CIERRE IS NULL THEN
        DELETE FROM CU_RESULTADO_BANCO_CONSOLIDADO;
    ELSE
        DELETE FROM CU_RESULTADO_BANCO_CONSOLIDADO
        WHERE FECHA_PROCESO = V_FECHA_CIERRE;
    END IF;

    /* ---------------------------------------------------------------------------
       2. Carga: Planeamiento (saldos de cierre y variación) + Saldos operativos (promedios)
       --------------------------------------------------------------------------- */
    INSERT INTO CU_RESULTADO_BANCO_CONSOLIDADO (
        FECHA_PROCESO, DES_TIPO, DES_CATEGORIA, DES_CATEGORIA_2,
        COD_MODULO_PRODUCTO, DES_MODULO, DES_BANCA, DES_BANCA_CLASIFICACION, NUM_CUENTA_BT,
        nivel_00, nivel_01, nivel_02, nivel_03, nivel_04, nivel_05,
        Flag_fecha_maxima, Clasificacion,
        Saldo_MO, Saldo_MN, Saldo_ME,
        Saldo_Mes_MO, Saldo_Mes_MN, Saldo_Mes_ME,
        Saldo_prm_MO, Saldo_prm_MN, Saldo_prm_ME,
        Saldo_x_Tasa_MO, Saldo_x_Tasa_MN, Saldo_x_Tasa_ME,
        Saldo_x_Tasa_COF_MO, Saldo_x_Tasa_COF_MN, Saldo_x_Tasa_COF_ME,
        Saldo_Vencido_MO, Saldo_Vencido_MN,
        Saldo_Refinanciado_MO, Saldo_Refinanciado_MN,
        Saldo_Judicial_MO, Saldo_Judicial_MN,
        TOTAL_MTO_PROVISIONES
    )
    -- 2.1 PLANEAMIENTO: saldo de cierre + variación del mes
    SELECT
        P.FECHA_PROCESO, P.DES_TIPO, P.DES_CATEGORIA, P.DES_CATEGORIA_2,
        P.COD_MODULO_PRODUCTO, P.DES_MODULO, P.DES_BANCA, P.DES_BANCA_CLASIFICACION, P.NUM_CUENTA_BT,
        P.nivel_00, P.nivel_01, P.nivel_02, P.nivel_03, P.nivel_04, P.nivel_05,
        0  AS Flag_fecha_maxima,
        '' AS Clasificacion,
        SUM(P.Saldo_MO), SUM(P.Saldo_MN), SUM(P.Saldo_ME),
        SUM(P.MTO_MES_MO), SUM(P.MTO_MES_MN), SUM(P.MTO_MES_ME),
        0, 0, 0,          -- promedios
        0, 0, 0,          -- saldo x tasa
        0, 0, 0,          -- saldo x tasa COF
        0, 0,             -- vencido
        0, 0,             -- refinanciado
        0, 0,             -- judicial
        0                 -- provisiones
    FROM CU_RESULTADO_BANCO_CONSOLIDADO_PLANEAMIENTO P
    WHERE P.FECHA_PROCESO = LAST_DAY(P.FECHA_PROCESO)
      AND (V_FECHA_CIERRE IS NULL OR P.FECHA_PROCESO = V_FECHA_CIERRE)
    GROUP BY P.FECHA_PROCESO, P.DES_TIPO, P.DES_CATEGORIA, P.DES_CATEGORIA_2,
             P.COD_MODULO_PRODUCTO, P.DES_MODULO, P.DES_BANCA, P.DES_BANCA_CLASIFICACION, P.NUM_CUENTA_BT,
             P.nivel_00, P.nivel_01, P.nivel_02, P.nivel_03, P.nivel_04, P.nivel_05

    UNION ALL

    -- 2.2 SALDOS OPERATIVOS: saldos, promedios, tasas, calidad de cartera y provisiones
    SELECT
        S.FECHA_PROCESO, S.DES_TIPO, S.DES_CATEGORIA, S.DES_CATEGORIA_2,
        S.COD_MODULO, S.DES_MODULO, S.DES_BANCA, S.DES_BANCA_CLASIFICACION, S.NUM_CUENTA_BT,
        S.nivel_00, S.nivel_01, S.nivel_02, S.nivel_03, S.nivel_04, S.nivel_05,
        0  AS Flag_fecha_maxima,
        '' AS Clasificacion,
        SUM(S.Saldo_MO), SUM(S.Saldo_MN), SUM(S.Saldo_ME),
        0, 0, 0,          -- variación del mes (solo viene de Planeamiento)
        SUM(S.Saldo_prm_MO), SUM(S.Saldo_prm_MN), SUM(S.Saldo_prm_ME),
        SUM(S.TOTAL_MTO_SALDO_X_TASA_MO),     SUM(S.TOTAL_MTO_SALDO_X_TASA_MN),     SUM(S.TOTAL_MTO_SALDO_X_TASA_ME),
        SUM(S.TOTAL_MTO_SALDO_X_TASA_COF_MO), SUM(S.TOTAL_MTO_SALDO_X_TASA_COF_MN), SUM(S.TOTAL_MTO_SALDO_X_TASA_COF_ME),
        SUM(S.TOTAL_MTO_VENCIDO_MO),          SUM(S.TOTAL_MTO_VENCIDO_MN),
        SUM(S.TOTAL_MTO_REFINANCIADO_MO),     SUM(S.TOTAL_MTO_REFINANCIADO_MN),
        SUM(S.TOTAL_MTO_JUDICIAL_MO),         SUM(S.TOTAL_MTO_JUDICIAL_MN),
        SUM(S.TOTAL_MTO_PROVISIONES)
    FROM CU_SALDOS_OPERATIVOS_RESULTADO_BANCO_CONSOLIDADO S
    WHERE S.FECHA_PROCESO = LAST_DAY(S.FECHA_PROCESO)
      AND (V_FECHA_CIERRE IS NULL OR S.FECHA_PROCESO = V_FECHA_CIERRE)
    GROUP BY S.FECHA_PROCESO, S.DES_TIPO, S.DES_CATEGORIA, S.DES_CATEGORIA_2,
             S.COD_MODULO, S.DES_MODULO, S.DES_BANCA, S.DES_BANCA_CLASIFICACION, S.NUM_CUENTA_BT,
             S.nivel_00, S.nivel_01, S.nivel_02, S.nivel_03, S.nivel_04, S.nivel_05;

    V_FILAS = ROW_COUNT();

    /* ---------------------------------------------------------------------------
       3. Flag del último cierre cargado  [C02] [C03]
       --------------------------------------------------------------------------- */
    V_FECHA_MAX = SCALAR(SELECT MAX(FECHA_PROCESO) FROM CU_RESULTADO_BANCO_CONSOLIDADO);

    UPDATE CU_RESULTADO_BANCO_CONSOLIDADO
       SET Flag_fecha_maxima = 0
     WHERE Flag_fecha_maxima = 1
       AND FECHA_PROCESO <> V_FECHA_MAX;

    UPDATE CU_RESULTADO_BANCO_CONSOLIDADO
       SET Flag_fecha_maxima = 1
     WHERE FECHA_PROCESO = V_FECHA_MAX
       AND Flag_fecha_maxima <> 1;

    COMMIT;

    /* ---------------------------------------------------------------------------
       Log de fin
       --------------------------------------------------------------------------- */
    IF V_FILAS = 0 THEN
        V_MSG = CONCAT('No se insertaron filas para el cierre ',
                       COALESCE(CAST(V_FECHA_CIERRE AS CHAR), 'COMPLETO'),
                       '. Verifica que Planeamiento y SP_CU_SALDOS_OPERATIVOS_RESULTADO_BANCO hayan corrido.');
    END IF;

    UPDATE ctl_log_proceso
       SET estado           = CASE WHEN V_MSG IS NULL THEN 'TERMINADO' ELSE 'WARNING' END,
           fec_termino      = NOW(6),
           filas_insertadas = V_FILAS,
           msg_error        = V_MSG
     WHERE id_log = V_ID_LOG;

EXCEPTION
    WHEN OTHERS THEN
        ROLLBACK;
        UPDATE ctl_log_proceso
           SET estado      = 'ERROR',
               fec_termino = NOW(6),
               msg_error   = CONCAT('Error procesando cierre ',
                                    COALESCE(CAST(V_FECHA_CIERRE AS CHAR), 'COMPLETO'),
                                    ' (ver detalle en el cliente / logs del motor)')
         WHERE id_log = V_ID_LOG;
        RAISE;
END //

DELIMITER ;

/* ------------------------------------------------------------------------------------
   Ejecución
   ------------------------------------------------------------------------------------
   CALL SP_CU_RESULTADO_BANCO_CONSOLIDADO('2026-10-31');   -- un cierre
   CALL SP_CU_RESULTADO_BANCO_CONSOLIDADO(NULL);           -- recarga completa
   ------------------------------------------------------------------------------------ */
