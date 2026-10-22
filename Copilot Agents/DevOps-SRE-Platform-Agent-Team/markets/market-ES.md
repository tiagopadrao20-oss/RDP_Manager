# Market ES

- `market_code`: `ES`
- `repo_root`: `Accipiens-ES`
- `core_paths`:
  - `pipelines`: `Accipiens-ES/TaskGroups/`, `YamlPipelines/`
  - `scripts`: `Accipiens-ES/Tools/`, `VWFS/Scripts/`
  - `tools`: `Accipiens-ES/Tools/`
- `environments`: `DEV`, `INT`, `CONS`, `PROD` (confirmar por pedido)
- `critical_systems`: Accipiens WebServices e FE deployments
- `deployment_constraints`: releases coordenados entre `BL` e `FE`
- `approval_rules`: produção exige confirmação explícita de janela
- `security_notes`: evitar segredos em `web.config` e templates
- `observability_notes`: validar alertas em app + infra após deploy
- `known_risks`: drift de configuração entre `BL` e `FE`
- `handoff_defaults`:
  - primary: `devops-ci-cd-agent`
  - secondary: `platform-engineering-agent`, `security-compliance-agent`
