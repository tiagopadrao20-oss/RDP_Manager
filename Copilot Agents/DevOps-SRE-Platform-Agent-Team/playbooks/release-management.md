# Playbook — Release Management

## Pré-release
1. Verificar readiness (artefactos, approvals, janela).
2. Confirmar variáveis e segredos por ambiente.
3. Validar plano de rollback e critérios de abort.

## Durante release
1. Executar deploy por etapas com checkpoints.
2. Monitorizar erros, latência e saturação.
3. Pausar em qualquer sinal crítico.

## Pós-release
1. Validar smoke tests e fluxos críticos de negócio.
2. Confirmar ausência de regressões operacionais.
3. Publicar resumo de release e próximos passos.
