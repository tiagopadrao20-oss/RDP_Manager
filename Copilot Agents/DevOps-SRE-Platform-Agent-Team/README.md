# DevOps/SRE/Platform Agent Team

Equipa multi-agent com modelo **hub-and-spoke**:
- Tu falas apenas com o `Team Leader`.
- O `Team Leader` classifica o pedido e delega a cada especialista.
- O resultado final volta para ti como uma resposta unificada.

## Objetivo
Criar uma equipa de agentes especializados em tópicos de **DevOps, SRE e Platform Engineering**, com regras consistentes e um fluxo de trabalho claro, inspirado nos teus agentes atuais em `Copilot Agents/` e `azure-platform/configs/`.

## Estrutura

```text
DevOps-SRE-Platform-Agent-Team/
  README.md
  agents/
    team-leader.prompt.md
    devops-ci-cd-agent.prompt.md
    sre-reliability-agent.prompt.md
    platform-engineering-agent.prompt.md
    security-compliance-agent.prompt.md
    observability-agent.prompt.md
  shared/
    rules/
      global-guardrails.md
    routing/
      routing-matrix.md
      market-selector.md
    handoffs/
      task-contract.md
  markets/
    _market-template.md
    market-PT.md
    market-ES.md
    market-DE.md
    market-UK.md
  playbooks/
    incident-response.md
    release-management.md
  templates/
    task-intake-template.md
    response-template.md
```

## Como usar
1. Abrir `agents/team-leader.prompt.md` como prompt principal.
2. O Team Leader identifica o mercado com `shared/routing/market-selector.md`.
3. O Team Leader carrega `markets/market-<code>.md` (`PT`, `ES`, `DE`, `UK`).
4. O Team Leader segue `shared/routing/routing-matrix.md` para decidir delegação.
5. Cada handoff usa o contrato em `shared/handoffs/task-contract.md`.
6. Todos os agentes seguem `shared/rules/global-guardrails.md`.

## Modo Market-Aware (v2)
- `PT`: contexto de `Accipiens-PT`
- `ES`: contexto de `Accipiens-ES`
- `DE`: contexto de `Accipiens-DE`
- `UK`: contexto de `Accipiens-UK`

Se o pedido for transversal, o Team Leader opera em modo `cross-market` e separa owners por mercado.

## Princípios herdados dos teus agentes atuais
- Não assumir informação em falta; perguntar quando necessário.
- Reutilizar artefactos existentes antes de criar novos.
- Evitar hardcoding de credenciais/segredos.
- Resposta orientada a ação com passos claros de validação.
- Sempre terminar com confirmação: **KEEP ou UNDO**.
