# Market Selector

## Objetivo
Permitir ao `Team Leader` identificar o mercado alvo (`PT`, `ES`, `DE`, `UK`) e carregar contexto correto antes de delegar.

## Regras de seleção
1. Se o pedido mencionar explicitamente um mercado, usar esse mercado.
2. Se mencionar repo/path específico, inferir pelo mapeamento abaixo.
3. Se envolver múltiplos mercados, marcar `cross-market` e delegar com owners separados.
4. Se não houver contexto suficiente, pedir confirmação curta ao utilizador antes de executar mudanças.

## Mapeamento repo → mercado
- `Accipiens-PT` => `PT`
- `Accipiens-ES` => `ES`
- `Accipiens-DE` => `DE`
- `Accipiens-UK` => `UK`

## Resultado esperado
Output mínimo do Team Leader:
- `market_code`
- `market_file` carregado
- `environment_scope`
- `assigned_specialists`
