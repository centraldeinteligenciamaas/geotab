# CLAUDE.md — Bootstrap de Contexto Persistente

> Arquivo portável. Copie-o para a raiz de QUALQUER projeto novo.
> O Claude CLI lê este arquivo automaticamente ao iniciar a sessão e segue as regras abaixo.
> O objetivo é **economizar tokens entre sessões** (especialmente ao fechar e reabrir o terminal).

---

## 0. PRIMEIRA AÇÃO DE TODA SESSÃO (obrigatório)

Ao iniciar, verifique se existe o arquivo `.claude/context.md`:

- **SE NÃO EXISTIR** → você está numa instalação nova. Execute o **MODO BOOTSTRAP** (seção 1).
- **SE EXISTIR** → execute o **MODO NORMAL** (seção 2). NÃO releia o projeto inteiro.

Não pule esta verificação.

---

## 1. MODO BOOTSTRAP (apenas na primeira vez)

Quando `.claude/context.md` não existe, faça uma ÚNICA varredura do projeto e gere-o:

1. Detecte automaticamente: linguagem(ns), framework, gerenciador de pacotes, banco de dados, libs principais, scripts de build/run, e estrutura de pastas.
2. Identifique os arquivos-chave (entrypoints, configs, módulos centrais) — ignore `node_modules`, `.venv`, `dist`, `build`, caches e afins.
3. Crie `.claude/context.md` preenchendo o template da seção 3 com o que descobriu.
4. Seja conciso: **caminho do arquivo + descrição de 1 linha**. NUNCA copie blocos de código para dentro do contexto.
5. Ao terminar, diga ao usuário: "Contexto inicial gerado em `.claude/context.md`. Próximas sessões usarão ele."

Regra de ouro: o bootstrap é a única vez que você varre o projeto inteiro. Depois disso, sempre leitura sob demanda.

---

## 2. MODO NORMAL (todas as demais sessões)

1. Leia APENAS `.claude/context.md` para entender o estado atual.
2. NÃO releia o projeto inteiro. Abra arquivos de código só quando a tarefa exigir, e o mínimo necessário.
3. Ao concluir mudanças relevantes, ATUALIZE `.claude/context.md`:
   - Edite apenas o que mudou (estado atual, próximos passos, gotchas novos, data da última sessão).
   - Não regenere o arquivo do zero.
   - Mantenha-o curto (alvo: < 150 linhas).
4. ATUALIZE TAMBÉM o `MANUAL.md` (documentação humana do projeto) quando a mudança afetar
   o que ele documenta: novo arquivo, mudança de fluxo/operação, nova tabela/view, novo gotcha.
   - Edição incremental na seção correspondente + a data de "Última atualização" no topo. Não regenere.
   - Diferença de papéis: `.claude/context.md` = estado técnico enxuto p/ retomar a sessão (eu);
     `MANUAL.md` = documentação completa e legível p/ pessoas (usuário/equipe).

---

## 3. TEMPLATE de `.claude/context.md`

Use exatamente esta estrutura ao gerar o contexto (preencha entre colchetes):

```markdown
# Contexto — [NOME DO PROJETO]

## Stack
- [linguagem/framework, banco, libs principais, package manager]

## Como rodar
- [comando de build / run / test]

## Arquitetura (mapa de arquivos)
- `caminho/arquivo` — [o que faz, 1 linha]
- `caminho/arquivo` — [o que faz, 1 linha]

## Estado atual
- [o que funciona / o que está em andamento]

## Decisões importantes
- [decisão] porque [motivo]

## Gotchas / armadilhas
- [erro conhecido + solução]

## Próximos passos
- [ ] [pendência]

## Última sessão
- Data: [AAAA-MM-DD]
- Resumo: [2-3 linhas do que foi feito]
```

---

## 4. ATALHOS para o usuário

- Abrir sessão: `"Leia o contexto e me diga onde paramos."`
- Fechar / pausar: `"Atualize o contexto com o que fizemos. Edite só o que mudou."`
- Forçar regeneração (se o projeto mudou muito): `"Refaça o bootstrap do contexto do zero."`

---

## 5. PRINCÍPIOS (não violar)

- Caminhos, não conteúdo: o contexto aponta *onde* está a informação; abra o arquivo só se precisar.
- Atualização incremental sempre; regeneração total só sob pedido explícito.
- Um `.claude/context.md` por projeto. Não misturar projetos.
- Projeto grande? Divida em `.claude/context-<área>.md` e liste-os no topo do contexto principal.