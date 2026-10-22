# Routing Matrix (Team Leader)

| Tipo de pedido | Agente primário | Agentes secundários | Exemplos |
|---|---|---|---|
| Build, release, deployment, Azure DevOps YAML | `devops-ci-cd-agent` | `security-compliance-agent`, `sre-reliability-agent` | Falha em pipeline, converter classic para YAML, gates de release |
| Incidentes, outages, MTTR, estabilidade | `sre-reliability-agent` | `observability-agent`, `platform-engineering-agent` | Serviço indisponível, erro intermitente, tuning de SLO |
| IaC, landing zones, self-service platform | `platform-engineering-agent` | `security-compliance-agent`, `devops-ci-cd-agent` | Padronização de ambiente, módulos Terraform, golden paths |
| IAM, segredos, hardening, compliance | `security-compliance-agent` | `platform-engineering-agent`, `sre-reliability-agent` | Segregação de acessos, policy-as-code, baselines |
| Logging, metrics, traces, alerting | `observability-agent` | `sre-reliability-agent`, `platform-engineering-agent` | Ruído de alertas, dashboards, tracing distribuído |

## Regras de decisão
1. Se o pedido tocar produção + risco operacional, envolver sempre `sre-reliability-agent`.
2. Se envolver credenciais/compliance, envolver sempre `security-compliance-agent`.
3. Se houver dúvida de domínio, começar por triagem curta e delegar em paralelo.
4. Consolidar sempre em plano único com owner, prazo e rollback.
5. Em pedidos `cross-market`, definir owner por mercado (`PT`, `ES`, `DE`, `UK`) e um owner global de coordenação.
6. Em `cross-market`, harmonizar guardrails no baseline mais restritivo entre os mercados envolvidos.
