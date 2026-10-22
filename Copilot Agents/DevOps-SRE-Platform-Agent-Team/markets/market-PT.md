# Market PT

- `market_code`: `PT`
- `repo_root`: `Accipiens-PT`
- `core_paths`:
  - `pipelines`: `Accipiens-PT/Documentation/Monitoring and Automation/` + `YamlPipelines/`
  - `scripts`: `Accipiens-PT/Tools/`, `VWFS/Scripts/`
  - `tools`: `Accipiens-PT/Tools/`
- `environments`: `DEV`, `CONS`, `PROD`
- `critical_systems`: Scheduler, SSRS, SQL reporting flows
- `deployment_constraints`: aprovações reforçadas em PROD e janelas fora de horário crítico
- `approval_rules`: mudanças de automação em PROD requerem validação explícita
- `security_notes`: credenciais via variable groups / cofres; nunca inline
- `observability_notes`: monitorização diária de scheduler e alerting de operações
- `known_risks`: jobs agendados com dependências em shares e SMTP
- `handoff_defaults`:
  - primary: `devops-ci-cd-agent`
  - secondary: `sre-reliability-agent`, `security-compliance-agent`
