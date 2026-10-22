# Market UK

- `market_code`: `UK`
- `repo_root`: `Accipiens-UK`
- `core_paths`:
  - `pipelines`: `YamlPipelines/` + automações UK
  - `scripts`: `Accipiens-UK/Scripts/`, `VWFS/Scripts/`
  - `tools`: `Accipiens-UK/Tools/`
- `environments`: `DEV`, `INT`, `CONS`, `PROD` (confirmar em cada pedido)
- `critical_systems`: `Accipiens` BL/FE e fluxos de autenticação
- `deployment_constraints`: alterações de autenticação exigem validação prévia em não-prod
- `approval_rules`: produção com aprovação explícita + checklist de segurança
- `security_notes`: hardening e scripts de encriptação são obrigatórios em mudanças sensíveis
- `observability_notes`: validar logs de autenticação e erros aplicacionais após release
- `known_risks`: regressões em auth e configuração web
- `handoff_defaults`:
  - primary: `security-compliance-agent`
  - secondary: `devops-ci-cd-agent`, `sre-reliability-agent`
