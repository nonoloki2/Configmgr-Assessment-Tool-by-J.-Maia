# Management Point Assessment Specification

Version: 2.0.1-alpha Build 0014

## Scope

Build 0014 focuses on the first real Management Point assessment layer: connectivity, core services and IIS prerequisites.

## Evidence model

Every non-healthy finding must include evidence, source and recommendation. The tool does not infer compliance without collected evidence.

## Checks in Build 0014

### MP-001 Role discovery
Source: Discovery inventory / SMS_SystemResourceList.

### MP-002 Connectivity
DNS, Ping and WinRM. Ping failure is Warning by default because ICMP may be blocked while the server remains manageable.

### MP-003 Services
SMS_EXECUTIVE, SMS_SITE_COMPONENT_MANAGER, W3SVC, Winmgmt, RemoteRegistry and BITS. W3SVC and SMS_EXECUTIVE stopped are high-impact indicators for a Management Point.

### MP-004 IIS prerequisites
Checks IIS feature presence: Web-Server, Web-Windows-Auth, Web-ISAPI-Ext, Web-Metabase and Web-WMI.

### MP-005 Required HTTP verbs
Checks IIS request filtering for GET, POST, CCM_POST, HEAD and PROPFIND.

## Future builds

Build 0015: certificates, HTTPS/Enhanced HTTP and endpoint tests.

Build 0016: MPControl.log evidence mode.
