/*
================================================================================
 SCCM Monthly Patch Dashboard - ETAPA 1
 Query de compliance com resolução automática de:
   - AssignmentID (deployment do mês corrente, pelo padrão de nome do SUG)
   - Lista de KBs (Article IDs dos CIs vinculados ao deployment, cobre
     qualquer versão do Windows - 22H2/23H2/24H2/25H2 - sem hardcode)
   - Ciclo de patch (início = 2ª terça-feira do mês / Patch Tuesday,
     dia corrente do ciclo, data de término do ciclo de 30 dias)

 Requer apenas o ajuste do @CollectionID e do @DeploymentNamePattern
 (este último só muda se a convenção de nomenclatura dos deployments mudar).
 Tudo o mais é resolvido automaticamente a cada execução - pode rodar
 todo dia, o ano inteiro, sem intervenção manual.
================================================================================
*/

SET NOCOUNT ON;

/* ============================================================
   1) PARÂMETROS DE AMBIENTE
   ============================================================ */

/*
   O CollectionID NÃO é mais escolhido manualmente aqui — ele é
   derivado automaticamente, mais abaixo, a partir da própria coleção
   alvo do deployment resolvido (evita o dashboard reportar uma
   coleção diferente da que o deployment realmente atinge).
*/

/*
   Padrão de nome do Deployment (SUG) no console, com placeholders {YYYY} e {MM}.
   Baseado no exemplo: "Desktop Deployment - Enterprise Production - Windows - 2026 - 07"
   Ajustar aqui se a convenção de nome mudar futuramente.
*/
DECLARE @DeploymentNamePattern NVARCHAR(200) =
    'Desktop Deployment - Enterprise Production - Windows - {YYYY} - {MM}';


/* ============================================================
   2) RESOLUÇÃO DO MÊS DE REFERÊNCIA DO CICLO
      Se hoje ainda for antes da Patch Tuesday deste mês, o ciclo
      "corrente" ainda é o do mês anterior (o SUG do mês atual
      pode nem ter sido criado ainda). Resolvido ANTES de procurar
      o AssignmentID, para os dois nunca ficarem dessincronizados.
   ============================================================ */

DECLARE @Today DATE = CAST(GETDATE() AS DATE);

DECLARE @RefTuesday DATE = '20000104';   -- terça-feira confirmada, usada como âncora de cálculo
DECLARE @ThisMonthFirstDay DATE = DATEFROMPARTS(YEAR(@Today), MONTH(@Today), 1);
DECLARE @ThisMonthOffsetToTuesday INT = (7 - (DATEDIFF(DAY, @RefTuesday, @ThisMonthFirstDay) % 7)) % 7;
DECLARE @ThisMonthFirstTuesday DATE = DATEADD(DAY, @ThisMonthOffsetToTuesday, @ThisMonthFirstDay);
DECLARE @ThisMonthPatchTuesday DATE = DATEADD(DAY, 7, @ThisMonthFirstTuesday);  -- 2ª terça-feira deste mês

DECLARE @RefMonthFirstDay DATE;
IF @Today >= @ThisMonthPatchTuesday
    SET @RefMonthFirstDay = @ThisMonthFirstDay;                       -- ciclo já começou este mês
ELSE
    SET @RefMonthFirstDay = DATEADD(MONTH, -1, @ThisMonthFirstDay);   -- ciclo ainda é o do mês anterior

DECLARE @YYYY NVARCHAR(4) = CAST(YEAR(@RefMonthFirstDay) AS NVARCHAR(4));
DECLARE @MM   NVARCHAR(2) = RIGHT('0' + CAST(MONTH(@RefMonthFirstDay) AS NVARCHAR(2)), 2);


/* ============================================================
   3) RESOLUÇÃO DO ASSIGNMENT ID DO CICLO DE REFERÊNCIA
   ============================================================ */

DECLARE @AssignmentID INT;
DECLARE @ResolvedDeploymentName NVARCHAR(256);
DECLARE @CollectionID NVARCHAR(8);          -- resolvido a partir do proprio deployment, nao mais manual
DECLARE @ResolvedCollectionName NVARCHAR(256);

/*
   Comparação tolerante a espaços: em vez de exigir o texto idêntico
   caractere a caractere, exige apenas o prefixo fixo do nome + o
   ano + o mês aparecendo em ordem, ignorando diferenças de espaçamento
   ao redor dos hífens.
*/
DECLARE @PatternPrefix NVARCHAR(200) = LTRIM(RTRIM(LEFT(@DeploymentNamePattern, CHARINDEX('{YYYY}', @DeploymentNamePattern) - 1)));

SELECT TOP 1
    @AssignmentID = cia.AssignmentID,
    @ResolvedDeploymentName = cia.AssignmentName,
    @CollectionID = cia.CollectionID
FROM v_CIAssignment AS cia
WHERE cia.AssignmentName LIKE '%' + @PatternPrefix + '%' + @YYYY + '%' + @MM + '%'
ORDER BY cia.AssignmentID DESC;

IF @AssignmentID IS NOT NULL
BEGIN
    SELECT @ResolvedCollectionName = coll.Name
    FROM v_Collection AS coll
    WHERE coll.CollectionID = @CollectionID;
END

IF @AssignmentID IS NULL
BEGIN
    DECLARE @Candidates NVARCHAR(MAX) = (
        SELECT STRING_AGG(CAST(cia2.AssignmentName AS NVARCHAR(MAX)), ' | ')
        FROM v_CIAssignment AS cia2
        WHERE cia2.AssignmentName LIKE '%' + @YYYY + '%'
    );
    RAISERROR(
        'Nenhum deployment encontrado batendo com prefixo "%s" + ano %s + mes %s. Deployments de %s encontrados no console: %s',
        16, 1, @PatternPrefix, @YYYY, @MM, @YYYY, @Candidates
    );
    RETURN;
END


/* ============================================================
   4) RESOLUÇÃO DA LISTA DE KBs (a partir do próprio deployment,
      cobrindo automaticamente todas as versões do Windows
      incluídas nele - 22H2/23H2/24H2/25H2/etc.)
   ============================================================ */

DECLARE @KBs TABLE (KB NVARCHAR(20));
DECLARE @CIs TABLE (CI_ID INT);   -- usado para bater com v_UpdateComplianceStatus (fonte "oficial")

INSERT INTO @KBs (KB)
SELECT DISTINCT 'KB' + uci.ArticleID
FROM v_CIAssignmentToCI AS catci
JOIN v_UpdateCIs AS uci
    ON uci.CI_ID = catci.CI_ID
WHERE catci.AssignmentID = @AssignmentID
  AND uci.ArticleID IS NOT NULL
  AND uci.ArticleID <> '';

INSERT INTO @CIs (CI_ID)
SELECT DISTINCT catci.CI_ID
FROM v_CIAssignmentToCI AS catci
WHERE catci.AssignmentID = @AssignmentID;

IF NOT EXISTS (SELECT 1 FROM @KBs)
BEGIN
    RAISERROR(
        'O deployment "%s" (AssignmentID %d) foi encontrado, mas nenhum KB/ArticleID foi localizado nos CIs vinculados a ele. Verifique o conteúdo do SUG no console.',
        16, 1, @ResolvedDeploymentName, @AssignmentID
    );
    RETURN;
END


/* ============================================================
   5) RESOLUÇÃO DAS DATAS DO CICLO
      Início = 2ª terça-feira do mês de referência (já resolvido
      na seção 2). Duração = 30 dias corridos.
   ============================================================ */

DECLARE @RefMonthOffsetToTuesday INT = (7 - (DATEDIFF(DAY, @RefTuesday, @RefMonthFirstDay) % 7)) % 7;
DECLARE @RefMonthFirstTuesday DATE = DATEADD(DAY, @RefMonthOffsetToTuesday, @RefMonthFirstDay);

DECLARE @CycleStart DATE = DATEADD(DAY, 7, @RefMonthFirstTuesday);   -- 2ª terça-feira do mês de referência
DECLARE @CycleEnd   DATE = DATEADD(DAY, 29, @CycleStart);            -- 30 dias corridos (dia 1 a dia 30)
DECLARE @CycleDay   INT  = DATEDIFF(DAY, @CycleStart, @Today) + 1;


/* ============================================================
   5) DIAGNÓSTICO - útil para log da automação / conferência manual
   ============================================================ */

SELECT
    @AssignmentID            AS Resolved_AssignmentID,
    @ResolvedDeploymentName  AS Resolved_DeploymentName,
    @CollectionID            AS CollectionID,
    @ResolvedCollectionName  AS Resolved_CollectionName,
    @CycleStart               AS Cycle_Start_Date,
    @CycleEnd                 AS Cycle_End_Date,
    @CycleDay                 AS Cycle_Day_Number,
    (SELECT STRING_AGG(KB, ', ') FROM @KBs) AS Resolved_KBs;


/* ============================================================
   6) COMPLIANT DEVICES
      (mesma lógica original, agora com @AssignmentID e @KBs
      resolvidos automaticamente acima)
   ============================================================ */

WITH Members AS (
    SELECT fcm.ResourceID
    FROM v_FullCollectionMembership AS fcm
    WHERE fcm.CollectionID = @CollectionID
),
KBList AS (
    SELECT UPPER(KB) AS KBLabel
    FROM @KBs
),
BaseData AS (
    SELECT
        m.ResourceID,
        rs.Name0 AS ComputerName,

        LOWER(
            COALESCE(
                CASE
                    WHEN cs.UserName0 IS NOT NULL AND cs.UserName0 <> '' THEN
                        CASE
                            WHEN CHARINDEX('\', cs.UserName0) > 0
                                THEN SUBSTRING(cs.UserName0, CHARINDEX('\', cs.UserName0) + 1, LEN(cs.UserName0))
                            WHEN CHARINDEX('@', cs.UserName0) > 0
                                THEN LEFT(cs.UserName0, CHARINDEX('@', cs.UserName0) - 1)
                            ELSE cs.UserName0
                        END
                    ELSE NULL
                END,
                CASE
                    WHEN rs.User_Name0 IS NOT NULL AND rs.User_Name0 <> '' THEN
                        CASE
                            WHEN CHARINDEX('\', rs.User_Name0) > 0
                                THEN SUBSTRING(rs.User_Name0, CHARINDEX('\', rs.User_Name0) + 1, LEN(rs.User_Name0))
                            WHEN CHARINDEX('@', rs.User_Name0) > 0
                                THEN LEFT(rs.User_Name0, CHARINDEX('@', rs.User_Name0) - 1)
                            ELSE rs.User_Name0
                        END
                    ELSE NULL
                END
            )
        ) AS UserId,

        CONVERT(date, ch.LastActiveTime) AS LastActivity
    FROM Members AS m
    JOIN v_R_System AS rs ON rs.ResourceID = m.ResourceID
    LEFT JOIN v_GS_COMPUTER_SYSTEM AS cs ON cs.ResourceID = m.ResourceID
    LEFT JOIN v_GS_OPERATING_SYSTEM AS os ON os.ResourceID = m.ResourceID
    LEFT JOIN v_CH_ClientSummary AS ch ON ch.ResourceID = m.ResourceID

    /* COMPLIANT FILTER — mesma fonte que o console usa para o
       "Percent Compliant" do SUG: v_UpdateComplianceStatus.
       Status: 0=Unknown, 1=NotRequired (nao se aplica a essa versao do
       Windows), 2=Required (faltando = NAO compliant), 3=Installed.
       Compliant = nao falta nenhuma KB aplicavel (nada em Required=2)
       E pelo menos uma KB confirmada instalada (Installed=3). */
    WHERE NOT EXISTS (
        SELECT 1
        FROM v_UpdateComplianceStatus AS ucs
        WHERE ucs.ResourceID = m.ResourceID
          AND ucs.CI_ID IN (SELECT CI_ID FROM @CIs)
          AND ucs.Status = 2
    )
    AND EXISTS (
        SELECT 1
        FROM v_UpdateComplianceStatus AS ucs
        WHERE ucs.ResourceID = m.ResourceID
          AND ucs.CI_ID IN (SELECT CI_ID FROM @CIs)
          AND ucs.Status = 3
    )
),
AssignmentData AS (
    SELECT
        cia.AssignmentID,
        cas.ResourceID,
        coll.Name AS Collection_Name,
        coll.CollectionID AS Collection_ID,
        sn.StateName AS Status_State,
        cas.LastEnforcementMessageTime AS Last_Modification,
        cas.LastEnforcementErrorCode AS Error_Code_ExitCode
    FROM v_CIAssignment cia
    JOIN v_Collection coll ON cia.CollectionID = coll.CollectionID
    JOIN v_CIAssignmentStatus cas ON cia.AssignmentID = cas.AssignmentID
    JOIN v_R_System sys ON cas.ResourceID = sys.ResourceID
    JOIN v_AssignmentState_Combined assc
        ON cia.AssignmentID = assc.AssignmentID
       AND cas.ResourceID = assc.ResourceID
    JOIN v_StateNames sn
        ON assc.StateType = sn.TopicType
       AND sn.StateID = ISNULL(assc.StateID, 0)
    WHERE cia.AssignmentID = @AssignmentID
)

SELECT
    b.ComputerName,
    b.UserId,
    cdr.DeviceOSBuild AS FullOSBuild,
    b.LastActivity,
    adusr.Mail0 AS User_Email,
    a.Collection_Name,
    a.Collection_ID,
    a.Status_State,
    a.Last_Modification,
    a.Error_Code_ExitCode,

    CASE
        WHEN a.Error_Code_ExitCode IS NULL THEN NULL
        ELSE '0x' +
             SUBSTRING(
                 master.dbo.fn_varbintohexstr(
                     CONVERT(VARBINARY(4),
                        ((a.Error_Code_ExitCode % 4294967296 + 4294967296) % 4294967296)
                     )
                 ),
                 3,
                 8
             )
    END AS Hex_Error_Code,

    @CycleStart AS Cycle_Start_Date,
    @CycleDay   AS Cycle_Day_Number,
    'Compliant'  AS Compliance_Bucket

FROM BaseData b
LEFT JOIN AssignmentData a
    ON b.ResourceID = a.ResourceID
LEFT JOIN v_R_User adusr
    ON LOWER(adusr.User_Name0) = b.UserId
LEFT JOIN v_CombinedDeviceResources cdr
    ON cdr.MachineID = b.ResourceID
ORDER BY a.Status_State, b.ComputerName;


/* ============================================================
   7) NON-COMPLIANT DEVICES
      IMPORTANTE: no arquivo original, esta query usava uma lista de
      KBs diferente (KB5093998 / KB5094126 - de um ciclo anterior),
      o que geraria inconsistência entre os dois relatórios do mesmo
      ciclo. Aqui ambas as queries usam a MESMA @KBs resolvida acima,
      garantindo que compliant + non-compliant sempre somem o total
      do parque do ciclo corrente.
   ============================================================ */

WITH Members AS (
    SELECT fcm.ResourceID
    FROM v_FullCollectionMembership AS fcm
    WHERE fcm.CollectionID = @CollectionID
),
KBList AS (
    SELECT UPPER(KB) AS KBLabel
    FROM @KBs
),
BaseData AS (
    SELECT
        m.ResourceID,
        rs.Name0 AS ComputerName,

        LOWER(
            COALESCE(
                CASE
                    WHEN cs.UserName0 IS NOT NULL AND cs.UserName0 <> '' THEN
                        CASE
                            WHEN CHARINDEX('\', cs.UserName0) > 0
                                THEN SUBSTRING(cs.UserName0, CHARINDEX('\', cs.UserName0) + 1, LEN(cs.UserName0))
                            WHEN CHARINDEX('@', cs.UserName0) > 0
                                THEN LEFT(cs.UserName0, CHARINDEX('@', cs.UserName0) - 1)
                            ELSE cs.UserName0
                        END
                    ELSE NULL
                END,
                CASE
                    WHEN rs.User_Name0 IS NOT NULL AND rs.User_Name0 <> '' THEN
                        CASE
                            WHEN CHARINDEX('\', rs.User_Name0) > 0
                                THEN SUBSTRING(rs.User_Name0, CHARINDEX('\', rs.User_Name0) + 1, LEN(rs.User_Name0))
                            WHEN CHARINDEX('@', rs.User_Name0) > 0
                                THEN LEFT(rs.User_Name0, CHARINDEX('@', rs.User_Name0) - 1)
                            ELSE rs.User_Name0
                        END
                    ELSE NULL
                END
            )
        ) AS UserId,

        cs.Domain0 AS OSDomain,

        CONVERT(date, ch.LastActiveTime) AS LastActivity
    FROM Members AS m
    JOIN v_R_System AS rs ON rs.ResourceID = m.ResourceID
    LEFT JOIN v_GS_COMPUTER_SYSTEM AS cs ON cs.ResourceID = m.ResourceID
    LEFT JOIN v_GS_OPERATING_SYSTEM AS os ON os.ResourceID = m.ResourceID
    LEFT JOIN v_CH_ClientSummary AS ch ON ch.ResourceID = m.ResourceID
    /* NON-COMPLIANT = negacao logica exata do filtro compliant acima:
       falta alguma KB aplicavel (Required=2) OU nao ha confirmacao de
       instalacao (sem nenhuma Status=3) — inclui tambem quem ainda nao
       foi avaliado (sem nenhuma linha em v_UpdateComplianceStatus). */
    WHERE EXISTS (
        SELECT 1
        FROM v_UpdateComplianceStatus AS ucs
        WHERE ucs.ResourceID = m.ResourceID
          AND ucs.CI_ID IN (SELECT CI_ID FROM @CIs)
          AND ucs.Status = 2
    )
    OR NOT EXISTS (
        SELECT 1
        FROM v_UpdateComplianceStatus AS ucs
        WHERE ucs.ResourceID = m.ResourceID
          AND ucs.CI_ID IN (SELECT CI_ID FROM @CIs)
          AND ucs.Status = 3
    )
),
AssignmentData AS (
    SELECT
        cia.AssignmentID,
        cas.ResourceID,
        coll.Name AS Collection_Name,
        coll.CollectionID AS Collection_ID,
        sn.StateName AS Status_State,
        cas.LastEnforcementMessageTime AS Last_Modification,
        cas.LastEnforcementErrorCode AS Error_Code_ExitCode
    FROM v_CIAssignment cia
    JOIN v_Collection coll ON cia.CollectionID = coll.CollectionID
    JOIN v_CIAssignmentStatus cas ON cia.AssignmentID = cas.AssignmentID
    JOIN v_R_System sys ON cas.ResourceID = sys.ResourceID
    JOIN v_AssignmentState_Combined assc
        ON cia.AssignmentID = assc.AssignmentID
       AND cas.ResourceID = assc.ResourceID
    JOIN v_StateNames sn
        ON assc.StateType = sn.TopicType
       AND sn.StateID = ISNULL(assc.StateID, 0)
    WHERE cia.AssignmentID = @AssignmentID
)

SELECT
    b.ComputerName,
    b.UserId,
    b.OSDomain,
    cdr.DeviceOSBuild AS FullOSBuild,
    b.LastActivity,
    adusr.Mail0 AS User_Email,
    a.Collection_Name,
    a.Collection_ID,
    a.Status_State,
    a.Last_Modification,
    a.Error_Code_ExitCode,

    CASE
        WHEN a.Error_Code_ExitCode IS NULL THEN NULL
        ELSE '0x' +
             SUBSTRING(
                 master.dbo.fn_varbintohexstr(
                     CONVERT(VARBINARY(4),
                        ((a.Error_Code_ExitCode % 4294967296 + 4294967296) % 4294967296)
                     )
                 ),
                 3,
                 8
             )
    END AS Hex_Error_Code,

    @CycleStart   AS Cycle_Start_Date,
    @CycleDay     AS Cycle_Day_Number,
    'NonCompliant' AS Compliance_Bucket

FROM BaseData b
LEFT JOIN AssignmentData a ON b.ResourceID = a.ResourceID
LEFT JOIN v_R_User adusr ON LOWER(adusr.User_Name0) = b.UserId
LEFT JOIN v_CombinedDeviceResources cdr ON cdr.MachineID = b.ResourceID
ORDER BY a.Status_State, b.ComputerName;
