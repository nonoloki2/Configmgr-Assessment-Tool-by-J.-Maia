/*
Diagnóstico rápido — lista todos os textos reais de Status_State
(v_StateNames) que aparecem para o deployment atual, com a contagem
de dispositivos em cada um. Só leitura, não altera nada.
Rodar direto no CM_A03.
*/
DECLARE @AssignmentID INT = 16786195;  -- o mesmo que apareceu no cabeçalho do dashboard

SELECT
    sn.StateName AS Status_State,
    COUNT(*) AS DeviceCount
FROM v_CIAssignmentStatus AS cas
JOIN v_AssignmentState_Combined AS assc
    ON cas.AssignmentID = assc.AssignmentID
   AND cas.ResourceID = assc.ResourceID
JOIN v_StateNames AS sn
    ON assc.StateType = sn.TopicType
   AND sn.StateID = ISNULL(assc.StateID, 0)
WHERE cas.AssignmentID = @AssignmentID
GROUP BY sn.StateName
ORDER BY DeviceCount DESC;
