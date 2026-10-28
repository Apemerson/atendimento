# Serviços — gestão de ordens e contratos

Aplicação web em português para gestão de clientes, catálogo, ordens de serviço, contratos recorrentes e pagamentos registrados. A interface é responsiva; a API Express usa PostgreSQL e isola cada consulta e gravação por conta autenticada.

## Requisitos

- Node.js 20 ou posterior e npm.
- PostgreSQL 14 ou posterior, com acesso de rede e TLS configurado no provedor.
- Para autenticação, uma chave privada `JWT_SECRET` com pelo menos 32 bytes aleatórios.

## Instalação e execução local

1. Copie `.env.example` para `.env` e ajuste `DATABASE_URL` e `JWT_SECRET`. Nunca publique o arquivo `.env`.
2. Execute `npm install` e `npm run dev`.
3. Abra a URL local informada pelo Vite. A interface encaminha as chamadas `/api` para a API em `http://localhost:3001`.
4. Ao iniciar, a API aplica `server/schema.sql` de forma idempotente. Crie sua conta na tela inicial. Os valores do catálogo começam zerados para você defini-los conforme sua operação.

Para produção: `npm run build`; inicie com `npm start`, usando `NODE_ENV=production`, `DATABASE_URL`, `DATABASE_SSL` e `JWT_SECRET`. O servidor Express entrega os arquivos compilados. Use proxy HTTPS e limite de requisições no provedor. Tokens de sessão ficam no `sessionStorage` e expiram em sete dias.

## Banco, migração e isolamento

`server/schema.sql` cria os usuários, perfis dos prestadores, registros genéricos por tipo e contador de ordens. É a migração inicial (`001`). PostgreSQL aplica a unicidade `(user_id, type, id)`, senha bcrypt e contador atômico. A API valida a sessão JWT em rotas protegidas; o `user_id` vem exclusivamente da sessão verificada. Nunca aceite o identificador de conta enviado no corpo como permissão. Use apenas uma conexão SSL válida em produção e um segredo aleatório.

Os dados de demonstração da referência não são pré-carregados. O banco começa limpo por conta; o catálogo inicial contém nomes e categorias com valores zerados. E-mail de recuperação exige SMTP ou provedor de identidade. O endpoint atualmente responde sem confirmar se o e-mail existe e não envia mensagens. Ative essa integração antes de anunciar recuperação de senha. Configure MFA e rate limiting em ambiente exposto.

## Backup e manutenção

Configure backup automático e PITR no serviço PostgreSQL. Também é possível agendar `pg_dump --format=custom "$DATABASE_URL" > backup.dump` em uma rotina segura do provedor/CI, armazenando o resultado criptografado fora do banco. Confira periodicamente a restauração em uma instância de teste; não versionar cópias, dumps nem credenciais.

## Recorrência mensal

Nesta versão, o usuário gera a competência pela interface e revisa a ordem antes de salvar. A API impede emitir outra ordem para a mesma competência vinculada ao contrato apenas no fluxo da interface. A tela oferece um botão de geração manual. Não há cron mensal integrado nesta versão: para habilitar geração automática, configure um cron-job no provedor que invoque uma rotina autenticada no servidor, percorra contratos ativos com transação e constraint única por `(contract_id, competence)`, calcule a data de vencimento limitando o dia ao último dia do mês e gere somente uma ordem por competência. Reconfigure as mudanças futuras sem editar os snapshots das ordens já geradas.

## Limitações configuráveis

- O botão de impressão abre a impressão do navegador; use “Salvar como PDF” para baixar. Os estilos de impressão configuram folha A4 e repetição de cabeçalhos. Não há binário PDF gerado e armazenado pelo servidor.
- O formulário aceita pagamento registrado manualmente; a integração completa de pagamentos parciais, saldo recalculado, dia de vencimento contratual e formas configuráveis necessita completar a UI específica antes da utilização financeira em produção.
- Upload do logotipo requer bucket de armazenamento. Exportação em JSON é disponível por conta.
- Recuperação por e-mail, cron mensal e backup precisam ser configurados externamente conforme acima.
- Para proteger a numeração, o backend atribui identificador sequencial por conta. O prefixo editável, duplicação, arquivamento histórico completo, uploads seguros, bloqueio de competência concorrente e geração real automatizada requerem a respectiva integração.

Não utilize o documento como boleto, documento fiscal ou comprovante bancário. Nenhuma integração bancária ou fiscal está habilitada.

