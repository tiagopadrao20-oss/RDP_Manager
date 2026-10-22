# Market GR

- `market_code`: `GR`
- `repo_root`: `Accipiens-GR`
- `core_paths`:
  - `pipelines`: `Accipiens-GR/.azure-pipelines/` + `YamlPipelines/`
  - `scripts`: `Accipiens-GR/Scripts/`, `VWFS/Scripts/`
  - `tools`: `Accipiens-GR/Tools/`
- `environments`: `DEV`, `REC`, `INT`, `CONS`, `PROD`
- `critical_systems`: `Accipiens`, `RPT/SSRS`, `SQL` operational jobs
- `deployment_constraints`: coordenação por ambiente com dependências entre aplicação e componentes de reporting
- `approval_rules`: alterações em `CONS` e `PROD` exigem validação prévia e plano de rollback explícito
- `security_notes`: credenciais sempre por variable groups/CyberArk; não usar segredos inline
- `observability_notes`: validações pós-execução por logs de pipeline + confirmação de serviços/IIS/DB
- `known_risks`: execução em paralelo pode aumentar risco operacional em `CONS/PROD`
- `handoff_defaults`:
  - primary: `devops-ci-cd-agent`
  - secondary: `sre-reliability-agent`, `security-compliance-agent`
