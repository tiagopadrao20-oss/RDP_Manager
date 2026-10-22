# Market DE

- `market_code`: `DE`
- `repo_root`: `Accipiens-DE`
- `core_paths`:
  - `pipelines`: `YamlPipelines/` + artefactos de deployment por componentes DE
  - `scripts`: `Accipiens-DE/Scripts/`, `VWFS/Scripts/`
  - `tools`: `Accipiens-DE/Tools/`
- `environments`: `DEV`, `INT`, `CONS`, `PROD` (confirmar por fluxo)
- `critical_systems`: `Accipiens`, `EmployeePortal`, `POS`, `SplinterDesigner`
- `deployment_constraints`: forte coordenação multi-componente
- `approval_rules`: qualquer alteração transversal requer plano de rollback por componente
- `security_notes`: especial atenção a scripts de autenticação e integração externa
- `observability_notes`: alertas por serviço com separação por componente
- `known_risks`: dependências entre componentes podem amplificar blast radius
- `handoff_defaults`:
  - primary: `platform-engineering-agent`
  - secondary: `sre-reliability-agent`, `security-compliance-agent`
