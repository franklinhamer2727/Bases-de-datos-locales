/* =====================================================================================
   PROCEDIMIENTO : SP_BDS_SALDOS_OPERATIVOS_PRE_PROMEDIO_H6   (SingleStore, versión día a día)
   PARÁMETROS    : V_FECHA_PROCESO    -> se procesa del día 1 del mes hasta esta fecha
                   V_MODO_COMPATIBLE  -> 1 (por defecto) = columnas auxiliares iguales al SP original
                                         0 = columnas auxiliares corregidas (ver [COMPAT])

   RESULTADO (igual al SP original)
   -------------------------------------------------------------------------------------
   Cada llave (ID_OPERACION_CIERRE, COD_RUBRO) que aparece al menos una vez en el mes
   tiene UNA fila por día, del día 1 a V_FECHA_PROCESO:
     - Día hábil              -> saldo del día                       (ORIGINAL)
     - Fin de semana / feriado-> copia del último día hábil          (COPIA_HABIL)
                                 (IND_DIA_HABIL = 'N' en BDS_CALENDARIOS, COD_CALENDARIO = 1)
     - Día sin registro       -> montos en 0 y atributos del registro anterior más cercano
                                 o, si es antes de su primera aparición, los del primero
                                 (equivale a los rellenos INICIO / INTERMEDIO / FIN del original)

   CÓMO AHORRA MEMORIA
   -------------------------------------------------------------------------------------
   Un solo recorrido, día por día. En cada día:
     1. WRK_PP_DIA    <- filas del día de origen (unos 3 M), deduplicadas y con la llave armada.
                         En fines de semana y feriados se reutiliza la tabla del último día
                         hábil, sin volver a leer la fuente.
     2. Destino       <- WRK_PP_DIA                                   (ORIGINAL / COPIA_HABIL)
     3. Destino       <- llaves ya conocidas sin fila hoy, montos 0, atributos de su fila de ayer
     4. WRK_PP_LLAVES <- llaves nuevas de hoy (PRIMER_DIA = hoy)
     5. Destino       <- llaves nuevas × días anteriores del mes, montos 0 (relleno de inicio de mes)
   Cada sentencia se confirma sola (autocommit) y la memoria se libera al pasar al día
   siguiente. Como máximo hay en uso WRK_PP_DIA (unos 3 M) y WRK_PP_LLAVES (unos 3 M, solo
   3 columnas). Sin recursión, sin copias del mes completo y sin el GROUP BY final de unos 93 M.
   La llave es ID_OPERACION de BDS_SALDOS_CIERRE (sin CONCAT). Las tablas de trabajo usan
   SHARD KEY (ID_OPERACION_CIERRE), así que los joins se resuelven dentro de cada nodo, sin
   mover datos entre nodos. Lo ideal es que el destino use la misma SHARD KEY.

   [COMPAT] COLUMNAS AUXILIARES SEGÚN V_MODO_COMPATIBLE
   -------------------------------------------------------------------------------------
                         | 1 = igual al original                 | 0 = corregido
   ANIO/MES (copias)     | del día de ORIGEN (p. ej. el 1/10 dice mes 9) | del día generado
   ANIO/MES (rellenos)   | NULL                                  | del día generado
   TIPO_ORIGEN (rellenos)| NULL                                  | RELLENO_INICIO_MES / RELLENO
   IND_DIA_HABIL (rellenos)| 'S'                                 | el del calendario
   Día ausente en BDS_CALENDARIOS | relleno en 0                 | copia del último día hábil

   DIFERENCIAS INEVITABLES CON EL ORIGINAL
   -------------------------------------------------------------------------------------
   - Duplicados (misma llave, rubro y fecha) en BDS_SALDOS_CIERRE: el original elegía uno al
     azar (GROUP BY); aquí se toma la carga más reciente (FECHA_CARGA, BATCH_ID).
   - El DELETE ya NO borra el mismo mes de años anteriores (error del original, no se replica).
   - Filas con ID_OPERACION NULL se excluyen (no pueden formar una llave válida).

   REQUISITOS / RECOMENDACIONES
   -------------------------------------------------------------------------------------
   - Destino con SORT KEY (FECHA_PROCESO): el DELETE por día y la lectura de "ayer" usan
     eliminación de segmentos.
   - Una sola ejecución a la vez: las tablas WRK_PP_* son físicas con nombre fijo.
   ===================================================================================== */

DELIMITER //

CREATE OR REPLACE PROCEDURE SP_BDS_SALDOS_OPERATIVOS_PRE_PROMEDIO_H6(
    V_FECHA_PROCESO   DATE,
    V_MODO_COMPATIBLE TINYINT DEFAULT 1
)
AS
DECLARE
    V_NOMBRE_PROCESO   LONGTEXT = 'DATAHUB_BDS_SALDOS_OPERATIVOS_PRE_PROMEDIO';
    V_TABLA_ORIGEN     LONGTEXT = 'BDS_SALDOS_CIERRE';
    V_TABLA_DESTINO    LONGTEXT = 'BDS_SALDOS_OPERATIVOS_PRE_PROMEDIO_LIMPIO';
    V_MSG_ERROR        LONGTEXT = NULL;
    V_ID_LOG           BIGINT;
    V_FILAS            BIGINT = 0;

    V_MES_INI          DATE;
    V_FECHA_FIN        DATE;
    V_SEMILLA          DATE;      -- último día hábil del mes anterior
    V_DIA              DATE;
    V_AYER             DATE;
    V_ORIGEN           DATE;
    V_ORIGEN_CARGADO   DATE = NULL;
    V_HABIL            CHAR(1);
    V_EN_CAL           TINYINT;
    V_HAY_DATOS        TINYINT;
    V_DIAS_ESPERADOS   BIGINT;
    V_INCOMPLETAS      BIGINT = 0;
BEGIN
    V_FECHA_FIN = V_FECHA_PROCESO;
    V_MES_INI   = DATE_SUB(V_FECHA_FIN, INTERVAL DAY(V_FECHA_FIN) - 1 DAY);

    INSERT INTO ctl_log_proceso (nom_proceso, tabla_origen, tabla_destino, fec_inicio, estado)
    VALUES (V_NOMBRE_PROCESO, V_TABLA_ORIGEN, V_TABLA_DESTINO, NOW(), 'EJECUTANDO');
    V_ID_LOG = LAST_INSERT_ID();

    /* ==================================================================================
       0. CALENDARIO DEL MES (como máximo 32 filas: semilla + días del mes)
       ================================================================================== */
    SELECT MAX(C.FEC_CALENDARIO) INTO V_SEMILLA
    FROM BDS_CALENDARIOS C
    WHERE C.COD_CALENDARIO = 1
      AND C.IND_DIA_HABIL  = 'S'
      AND C.FEC_CALENDARIO <= DATE_SUB(V_MES_INI, INTERVAL 1 DAY);

    DROP TABLE IF EXISTS WRK_PP_CAL;
    DROP TABLE IF EXISTS WRK_PP_DIA;
    DROP TABLE IF EXISTS WRK_PP_LLAVES;

    -- Todos los días calendario (la recursión aquí genera como máximo 32 filas, no millones)
    CREATE TABLE WRK_PP_CAL AS
    WITH RECURSIVE DIAS AS (
        SELECT V_SEMILLA AS FECHA_PROCESO
        UNION ALL
        SELECT DATE_ADD(FECHA_PROCESO, INTERVAL 1 DAY)
        FROM DIAS
        WHERE FECHA_PROCESO < V_FECHA_FIN
    )
    SELECT
        D.FECHA_PROCESO,
        CASE WHEN C.FEC_CALENDARIO IS NULL THEN 0 ELSE 1 END       AS EN_CALENDARIO,
        COALESCE(C.IND_DIA_HABIL, 'N')                             AS IND_DIA_HABIL,
        -- último día hábil <= fecha (de ahí se copian los saldos en fines de semana y feriados)
        MAX(CASE WHEN C.IND_DIA_HABIL = 'S' THEN D.FECHA_PROCESO END)
            OVER (ORDER BY D.FECHA_PROCESO ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS FECHA_ORIGEN
    FROM DIAS D
    LEFT JOIN (
        SELECT FEC_CALENDARIO, MAX(IND_DIA_HABIL) AS IND_DIA_HABIL
        FROM BDS_CALENDARIOS
        WHERE COD_CALENDARIO = 1
          AND FEC_CALENDARIO BETWEEN V_SEMILLA AND V_FECHA_FIN
        GROUP BY FEC_CALENDARIO
    ) C ON C.FEC_CALENDARIO = D.FECHA_PROCESO;

    /* Llaves del mes (solo 3 columnas). Se crea vacía, con los mismos tipos que la llave. */
    CREATE TABLE WRK_PP_LLAVES (SHARD KEY (ID_OPERACION_CIERRE)) AS
    SELECT
        s.ID_OPERACION AS ID_OPERACION_CIERRE,
        s.COD_RUBRO,
        CAST(s.FECHA_PROCESO AS DATE) AS PRIMER_DIA
    FROM BDS_SALDOS_CIERRE s
    LIMIT 0;

    -- Restos de una corrida anterior con fecha posterior dentro del mismo mes
    DELETE FROM BDS_SALDOS_OPERATIVOS_PRE_PROMEDIO_LIMPIO
    WHERE FECHA_PROCESO >  V_FECHA_FIN
      AND FECHA_PROCESO <= LAST_DAY(V_FECHA_FIN);

    /* ==================================================================================
       1. RECORRIDO DÍA POR DÍA
       ================================================================================== */
    V_DIA = V_MES_INI;

    WHILE V_DIA <= V_FECHA_FIN LOOP

        V_AYER = DATE_SUB(V_DIA, INTERVAL 1 DAY);

        SELECT FECHA_ORIGEN, IND_DIA_HABIL, EN_CALENDARIO
        INTO   V_ORIGEN, V_HABIL, V_EN_CAL
        FROM WRK_PP_CAL
        WHERE FECHA_PROCESO = V_DIA;

        -- ¿Este día lleva saldos (originales o copia)?
        --   Modo compatible: un día ausente en BDS_CALENDARIOS no tiene saldos (el original lo rellenaba en 0)
        IF V_ORIGEN IS NULL OR (V_EN_CAL = 0 AND V_MODO_COMPATIBLE = 1) THEN
            V_HAY_DATOS = 0;
        ELSE
            V_HAY_DATOS = 1;
        END IF;

        -- 1.1 Limpieza del día en el destino (rango, sin MONTH(): no toca otros años)
        DELETE FROM BDS_SALDOS_OPERATIVOS_PRE_PROMEDIO_LIMPIO
        WHERE FECHA_PROCESO >= V_DIA
          AND FECHA_PROCESO <  DATE_ADD(V_DIA, INTERVAL 1 DAY);

        IF V_HAY_DATOS = 1 THEN

            -- 1.2 Carga del día de origen (solo si cambió: fines de semana y feriados reutilizan la tabla)
            IF V_ORIGEN_CARGADO IS NULL OR V_ORIGEN_CARGADO <> V_ORIGEN THEN
                DROP TABLE IF EXISTS WRK_PP_DIA;

                CREATE TABLE WRK_PP_DIA (SHARD KEY (ID_OPERACION_CIERRE)) AS
                SELECT
                    x.ID_OPERACION_CIERRE, x.COD_RUBRO, x.NUM_CUENTA_BT,
                    x.COD_EMPRESA, x.COD_SUCURSAL, x.COD_MONEDA, x.COD_PAPEL, x.PCT_TASA,
                    x.COD_OPERACION, x.COD_EJECUTIVO, x.COD_SUB_OPERACION, x.COD_TIPO_OPERACION,
                    x.COD_MODULO, x.COD_MODULO_PRODUCTO, x.FEC_VENCIMIENTO, x.FEC_VALOR,
                    x.IND_CATEGORIA_RIESGO, x.COD_ACTI_BCO_CENTRAL, x.COD_PRODUCTO, x.FUENTE,
                    x.MTO_SALDO_ORIGEN, x.MTO_SALDO_MN, x.MTO_SALDO_ME, x.MTO_SALDO_MO,
                    x.MTO_INTERES, x.MTO_PREVISIONES
                FROM (
                    SELECT
                        s.*,
                        s.ID_OPERACION AS ID_OPERACION_CIERRE,
                        ROW_NUMBER() OVER (
                            PARTITION BY s.ID_OPERACION, s.COD_RUBRO
                            ORDER BY s.FECHA_CARGA DESC, s.BATCH_ID DESC
                        ) AS RN
                    FROM BDS_SALDOS_CIERRE s
                    WHERE s.FECHA_PROCESO >= V_ORIGEN
                      AND s.FECHA_PROCESO <  DATE_ADD(V_ORIGEN, INTERVAL 1 DAY)
                      AND s.ID_OPERACION IS NOT NULL
                ) x
                WHERE x.RN = 1;

                V_ORIGEN_CARGADO = V_ORIGEN;
            END IF;

            -- 1.3 ORIGINAL (día hábil) / COPIA_HABIL (fin de semana o feriado)
            INSERT INTO BDS_SALDOS_OPERATIVOS_PRE_PROMEDIO_LIMPIO (
                ID_OPERACION_CIERRE, FECHA_PROCESO, COD_EMPRESA, ANIO, MES, COD_SUCURSAL, COD_RUBRO,
                COD_MONEDA, COD_PAPEL, PCT_TASA, NUM_CUENTA_BT, COD_OPERACION, COD_EJECUTIVO,
                COD_SUB_OPERACION, COD_TIPO_OPERACION, COD_MODULO, COD_MODULO_PRODUCTO,
                FEC_VENCIMIENTO, FEC_VALOR, IND_CATEGORIA_RIESGO, COD_ACTI_BCO_CENTRAL, COD_PRODUCTO,
                MTO_SALDO_ORIGEN, MTO_SALDO_MN, MTO_SALDO_ME, MTO_SALDO_MO, MTO_INTERES, MTO_PREVISIONES,
                IND_DIA_HABIL, TIPO_ORIGEN, FUENTE)
            SELECT
                d.ID_OPERACION_CIERRE, V_DIA, d.COD_EMPRESA,
                CASE WHEN V_MODO_COMPATIBLE = 1 THEN YEAR(V_ORIGEN)  ELSE YEAR(V_DIA)  END,
                CASE WHEN V_MODO_COMPATIBLE = 1 THEN MONTH(V_ORIGEN) ELSE MONTH(V_DIA) END,
                d.COD_SUCURSAL, d.COD_RUBRO,
                d.COD_MONEDA, d.COD_PAPEL, d.PCT_TASA, d.NUM_CUENTA_BT, d.COD_OPERACION, d.COD_EJECUTIVO,
                d.COD_SUB_OPERACION, d.COD_TIPO_OPERACION, d.COD_MODULO, d.COD_MODULO_PRODUCTO,
                d.FEC_VENCIMIENTO, d.FEC_VALOR, d.IND_CATEGORIA_RIESGO, d.COD_ACTI_BCO_CENTRAL, d.COD_PRODUCTO,
                d.MTO_SALDO_ORIGEN, d.MTO_SALDO_MN, d.MTO_SALDO_ME, d.MTO_SALDO_MO, d.MTO_INTERES, d.MTO_PREVISIONES,
                V_HABIL,
                CASE WHEN V_DIA = V_ORIGEN THEN 'ORIGINAL' ELSE 'COPIA_HABIL' END,
                d.FUENTE
            FROM WRK_PP_DIA d;

            V_FILAS = V_FILAS + ROW_COUNT();
        END IF;

        -- 1.4 Relleno de llaves YA CONOCIDAS que hoy no tienen registro
        --     (equivale al relleno INTERMEDIO y de FIN DE MES): atributos de su fila de ayer
        INSERT INTO BDS_SALDOS_OPERATIVOS_PRE_PROMEDIO_LIMPIO (
            ID_OPERACION_CIERRE, FECHA_PROCESO, COD_EMPRESA, ANIO, MES, COD_SUCURSAL, COD_RUBRO,
            COD_MONEDA, COD_PAPEL, PCT_TASA, NUM_CUENTA_BT, COD_OPERACION, COD_EJECUTIVO,
            COD_SUB_OPERACION, COD_TIPO_OPERACION, COD_MODULO, COD_MODULO_PRODUCTO,
            FEC_VENCIMIENTO, FEC_VALOR, IND_CATEGORIA_RIESGO, COD_ACTI_BCO_CENTRAL, COD_PRODUCTO,
            MTO_SALDO_ORIGEN, MTO_SALDO_MN, MTO_SALDO_ME, MTO_SALDO_MO, MTO_INTERES, MTO_PREVISIONES,
            IND_DIA_HABIL, TIPO_ORIGEN, FUENTE)
        SELECT
            p.ID_OPERACION_CIERRE, V_DIA, p.COD_EMPRESA,
            CASE WHEN V_MODO_COMPATIBLE = 1 THEN NULL ELSE YEAR(V_DIA)  END,
            CASE WHEN V_MODO_COMPATIBLE = 1 THEN NULL ELSE MONTH(V_DIA) END,
            p.COD_SUCURSAL, p.COD_RUBRO,
            p.COD_MONEDA, p.COD_PAPEL, p.PCT_TASA, p.NUM_CUENTA_BT, p.COD_OPERACION, p.COD_EJECUTIVO,
            p.COD_SUB_OPERACION, p.COD_TIPO_OPERACION, p.COD_MODULO, p.COD_MODULO_PRODUCTO,
            p.FEC_VENCIMIENTO, p.FEC_VALOR, p.IND_CATEGORIA_RIESGO, p.COD_ACTI_BCO_CENTRAL, p.COD_PRODUCTO,
            0, 0, 0, 0, 0, 0,
            CASE WHEN V_MODO_COMPATIBLE = 1 THEN 'S'  ELSE V_HABIL   END,
            CASE WHEN V_MODO_COMPATIBLE = 1 THEN NULL ELSE 'RELLENO' END,
            p.FUENTE
        FROM WRK_PP_LLAVES k
        JOIN BDS_SALDOS_OPERATIVOS_PRE_PROMEDIO_LIMPIO p
          ON  p.FECHA_PROCESO >= V_AYER
          AND p.FECHA_PROCESO <  V_DIA
          AND p.ID_OPERACION_CIERRE = k.ID_OPERACION_CIERRE
          AND p.COD_RUBRO           = k.COD_RUBRO
        WHERE V_HAY_DATOS = 0
           OR NOT EXISTS (
                SELECT 1 FROM WRK_PP_DIA d
                WHERE d.ID_OPERACION_CIERRE = k.ID_OPERACION_CIERRE
                  AND d.COD_RUBRO           = k.COD_RUBRO);

        V_FILAS = V_FILAS + ROW_COUNT();

        IF V_HAY_DATOS = 1 THEN

            -- 1.5 Llaves NUEVAS (primera aparición en el mes = hoy)
            INSERT INTO WRK_PP_LLAVES (ID_OPERACION_CIERRE, COD_RUBRO, PRIMER_DIA)
            SELECT d.ID_OPERACION_CIERRE, d.COD_RUBRO, V_DIA
            FROM WRK_PP_DIA d
            WHERE NOT EXISTS (
                SELECT 1 FROM WRK_PP_LLAVES k
                WHERE k.ID_OPERACION_CIERRE = d.ID_OPERACION_CIERRE
                  AND k.COD_RUBRO           = d.COD_RUBRO);

            -- 1.6 Relleno de INICIO DE MES para las llaves nuevas: días del 1 a ayer,
            --     montos en 0 y atributos de su primer registro (el de hoy)
            IF V_DIA > V_MES_INI THEN
                INSERT INTO BDS_SALDOS_OPERATIVOS_PRE_PROMEDIO_LIMPIO (
                    ID_OPERACION_CIERRE, FECHA_PROCESO, COD_EMPRESA, ANIO, MES, COD_SUCURSAL, COD_RUBRO,
                    COD_MONEDA, COD_PAPEL, PCT_TASA, NUM_CUENTA_BT, COD_OPERACION, COD_EJECUTIVO,
                    COD_SUB_OPERACION, COD_TIPO_OPERACION, COD_MODULO, COD_MODULO_PRODUCTO,
                    FEC_VENCIMIENTO, FEC_VALOR, IND_CATEGORIA_RIESGO, COD_ACTI_BCO_CENTRAL, COD_PRODUCTO,
                    MTO_SALDO_ORIGEN, MTO_SALDO_MN, MTO_SALDO_ME, MTO_SALDO_MO, MTO_INTERES, MTO_PREVISIONES,
                    IND_DIA_HABIL, TIPO_ORIGEN, FUENTE)
                SELECT
                    d.ID_OPERACION_CIERRE, c.FECHA_PROCESO, d.COD_EMPRESA,
                    CASE WHEN V_MODO_COMPATIBLE = 1 THEN NULL ELSE YEAR(c.FECHA_PROCESO)  END,
                    CASE WHEN V_MODO_COMPATIBLE = 1 THEN NULL ELSE MONTH(c.FECHA_PROCESO) END,
                    d.COD_SUCURSAL, d.COD_RUBRO,
                    d.COD_MONEDA, d.COD_PAPEL, d.PCT_TASA, d.NUM_CUENTA_BT, d.COD_OPERACION, d.COD_EJECUTIVO,
                    d.COD_SUB_OPERACION, d.COD_TIPO_OPERACION, d.COD_MODULO, d.COD_MODULO_PRODUCTO,
                    d.FEC_VENCIMIENTO, d.FEC_VALOR, d.IND_CATEGORIA_RIESGO, d.COD_ACTI_BCO_CENTRAL, d.COD_PRODUCTO,
                    0, 0, 0, 0, 0, 0,
                    CASE WHEN V_MODO_COMPATIBLE = 1 THEN 'S'  ELSE c.IND_DIA_HABIL        END,
                    CASE WHEN V_MODO_COMPATIBLE = 1 THEN NULL ELSE 'RELLENO_INICIO_MES' END,
                    d.FUENTE
                FROM WRK_PP_LLAVES k
                JOIN WRK_PP_DIA d
                  ON  d.ID_OPERACION_CIERRE = k.ID_OPERACION_CIERRE
                  AND d.COD_RUBRO           = k.COD_RUBRO
                JOIN WRK_PP_CAL c
                  ON  c.FECHA_PROCESO >= V_MES_INI
                  AND c.FECHA_PROCESO <  V_DIA
                WHERE k.PRIMER_DIA = V_DIA;

                V_FILAS = V_FILAS + ROW_COUNT();
            END IF;
        END IF;

        V_DIA = DATE_ADD(V_DIA, INTERVAL 1 DAY);
    END LOOP;

    /* ==================================================================================
       2. VALIDACIÓN: cada llave debe tener todos los días del 1 a V_FECHA_PROCESO
       ================================================================================== */
    V_DIAS_ESPERADOS = DATEDIFF(V_FECHA_FIN, V_MES_INI) + 1;

    SELECT COUNT(*) INTO V_INCOMPLETAS
    FROM (
        SELECT ID_OPERACION_CIERRE, COD_RUBRO
        FROM BDS_SALDOS_OPERATIVOS_PRE_PROMEDIO_LIMPIO
        WHERE FECHA_PROCESO >= V_MES_INI
          AND FECHA_PROCESO <  DATE_ADD(V_FECHA_FIN, INTERVAL 1 DAY)
        GROUP BY ID_OPERACION_CIERRE, COD_RUBRO
        HAVING COUNT(*) <> V_DIAS_ESPERADOS
    ) q;

    /* ==================================================================================
       3. LIMPIEZA Y LOG
       ================================================================================== */
    DROP TABLE IF EXISTS WRK_PP_CAL;
    DROP TABLE IF EXISTS WRK_PP_DIA;
    DROP TABLE IF EXISTS WRK_PP_LLAVES;

    IF V_FILAS = 0 THEN
        V_MSG_ERROR = 'No se insertaron registros en BDS_SALDOS_OPERATIVOS_PRE_PROMEDIO_LIMPIO';
    ELSEIF V_INCOMPLETAS > 0 THEN
        V_MSG_ERROR = CONCAT(V_INCOMPLETAS, ' llaves (operación, rubro) no tienen ', V_DIAS_ESPERADOS, ' días');
    END IF;

    IF V_MSG_ERROR IS NULL THEN
        UPDATE ctl_log_proceso
           SET estado = 'TERMINADO', fec_termino = NOW(6), filas_insertadas = V_FILAS
         WHERE id_log = V_ID_LOG;
    ELSE
        UPDATE ctl_log_proceso
           SET estado = 'WARNING', fec_termino = NOW(6), filas_insertadas = V_FILAS, msg_error = V_MSG_ERROR
         WHERE id_log = V_ID_LOG;
    END IF;

EXCEPTION
    WHEN OTHERS THEN
        DROP TABLE IF EXISTS WRK_PP_CAL;
        DROP TABLE IF EXISTS WRK_PP_DIA;
        DROP TABLE IF EXISTS WRK_PP_LLAVES;
        UPDATE ctl_log_proceso
           SET estado = 'ERROR', fec_termino = NOW(6), filas_insertadas = V_FILAS,
               msg_error = CONCAT('Error en el día ', COALESCE(V_DIA, V_MES_INI),
                                  '. Los días anteriores ya quedaron cargados; vuelve a ejecutar el mes.')
         WHERE id_log = V_ID_LOG;
        RAISE;
END //

DELIMITER ;

/* ------------------------------------------------------------------------------------
   Ejecución
   ------------------------------------------------------------------------------------
   CALL SP_BDS_SALDOS_OPERATIVOS_PRE_PROMEDIO_H6('2026-10-31');      -- igual al original
   CALL SP_BDS_SALDOS_OPERATIVOS_PRE_PROMEDIO_H6('2026-10-31', 0);   -- columnas auxiliares corregidas

   Verificación (debe devolver 0 filas):
   SELECT ID_OPERACION_CIERRE, COD_RUBRO, COUNT(*) AS dias
   FROM BDS_SALDOS_OPERATIVOS_PRE_PROMEDIO_LIMPIO
   WHERE FECHA_PROCESO BETWEEN '2026-10-01' AND '2026-10-31'
   GROUP BY ID_OPERACION_CIERRE, COD_RUBRO
   HAVING COUNT(*) <> 31;
   ------------------------------------------------------------------------------------ */
