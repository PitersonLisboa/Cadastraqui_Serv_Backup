# Cadastraqui — Serviço de Backup no Railway

Serviço separado que roda no Railway e faz backup automático diário do PostgreSQL para o Supabase Storage.

## Vantagens

- Roda 24/7 (não depende da sua máquina)
- Usa a URL interna do PostgreSQL (sem custo de egress)
- Container Alpine leve (~30 MB)
- Logs visíveis no Railway Dashboard

## Deploy no Railway

### 1. Criar o repositório

Crie um repositório no GitHub com estes 3 arquivos:

```
railway-backup/
├── Dockerfile
├── backup.sh
└── crontab
```

### 2. Criar serviço no Railway

1. Railway Dashboard → seu projeto Cadastraqui
2. **New** → **GitHub Repo** → selecione o repositório `railway-backup`
3. Railway vai detectar o Dockerfile e fazer o build automaticamente

### 3. Configurar variáveis

No serviço criado, vá em **Variables** e adicione:

| Variável | Valor | Obrigatória |
|----------|-------|-------------|
| `DATABASE_URL` | Referencie a variável do serviço PostgreSQL* | Sim |
| `SUPABASE_PROJECT_URL` | `https://SEU_ID.supabase.co` | Sim |
| `SUPABASE_SERVICE_ROLE_KEY` | Sua service role key | Sim |
| `SUPABASE_BUCKET` | `backups` | Não (padrão: backups) |
| `REMOTE_RETENTION_DAYS` | `30` | Não (padrão: 30) |

*Para o `DATABASE_URL`, use a referência interna do Railway:
- Clique em "Add Variable"
- Nome: `DATABASE_URL`
- Valor: `${{Postgres.DATABASE_URL}}` (Railway resolve automaticamente)

### 4. Verificar

- Railway Dashboard → serviço de backup → **Logs**
- Você deve ver o supercronic rodando e aguardando o próximo horário
- Para testar imediatamente, edite o `crontab` e descomente a linha `*/5 * * * *`

## Configuração do horário

Edite o arquivo `crontab`:

```cron
# Diário às 3h (Brasília)
0 3 * * * /app/backup.sh

# A cada 12 horas
0 3,15 * * * /app/backup.sh

# Só dias úteis às 2h
0 2 * * 1-5 /app/backup.sh
```

## Custo estimado

O container fica parado entre os backups (supercronic é leve), então consome pouquíssimos recursos. No plano Hobby do Railway, o impacto é mínimo.

## Pré-requisito no Supabase

Crie o bucket `backups` (privado) no Supabase Dashboard → Storage antes do primeiro backup.
