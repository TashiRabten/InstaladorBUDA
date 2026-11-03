-- supabase-fix-inbox.sql  v4
-- Schema da caixa de sugestões de mudança (fix_submissions) do InstaladorBUDA.
--
-- Pode ser aplicado num projeto Supabase existente sem conflito com outras tabelas.
-- As tabelas criadas aqui são: fix_submissions, fix_inbox_developers, fix_inbox_config.
--
-- ══════════════════════════════════════════════════════════════════════════════
-- COMO APLICAR  (leia antes de executar)
-- ══════════════════════════════════════════════════════════════════════════════
--
-- 1. Supabase Dashboard → SQL Editor → cole este arquivo → Run
--    O script é idempotente: pode rodar várias vezes sem problema.
--
-- 2. Se der qualquer erro, vá até a seção "RESET" abaixo, descomente o bloco
--    DROP, execute só aquela parte primeiro, depois execute o script inteiro.
--
-- ══════════════════════════════════════════════════════════════════════════════
-- RESET (opcional — só use se precisar apagar e recriar tudo do zero)
-- ══════════════════════════════════════════════════════════════════════════════
/*
drop table  if exists fix_submissions                                       cascade;
drop table  if exists fix_inbox_developers                                  cascade;
drop table  if exists fix_inbox_config                                      cascade;
drop function if exists fix_inbox_assert_passphrase(text);
drop function if exists fix_inbox_list(text, text);
drop function if exists fix_inbox_bundle(text, bigint);
drop function if exists fix_inbox_set_status(text, bigint, text, text, text, text);
drop function if exists fix_inbox_register_developer(text, text, text, text, text, text[], boolean);
drop function if exists fix_inbox_set_open(text, boolean, integer);
drop function if exists fix_set_updated_at();
*/

-- ══════════════════════════════════════════════════════════════════════════════
-- Extensão pgcrypto (bcrypt para a frase-senha do mantenedor)
-- ══════════════════════════════════════════════════════════════════════════════
create extension if not exists pgcrypto;

-- ══════════════════════════════════════════════════════════════════════════════
-- Tabela 1 — fix_inbox_config  (singleton: uma linha, id = 1)
-- ══════════════════════════════════════════════════════════════════════════════
create table if not exists fix_inbox_config (
    id              integer     primary key default 1 check (id = 1),
    passphrase_hash text        not null default '',
    inbox_open      boolean     not null default true,
    max_per_hour    integer     not null default 10 check (max_per_hour between 0 and 100),
    updated_at      timestamptz not null default now()
);

-- ══════════════════════════════════════════════════════════════════════════════
-- Tabela 2 — fix_inbox_developers  (desenvolvedores autorizados)
-- ══════════════════════════════════════════════════════════════════════════════
create table if not exists fix_inbox_developers (
    id            text        primary key,   -- auth.users.id (uuid como text)
    email         text        not null unique,
    developer_id  text        not null,
    key_id        text        not null,
    public_key    text        not null,
    apps          text[]      not null default '{}',
    active        boolean     not null default true,
    registered_at timestamptz not null default now(),
    updated_at    timestamptz not null default now()
);

-- ══════════════════════════════════════════════════════════════════════════════
-- Tabela 3 — fix_submissions  (bundles enviados pelos contribuidores)
-- ══════════════════════════════════════════════════════════════════════════════
create table if not exists fix_submissions (
    id              bigint      generated always as identity primary key,
    sender_id       uuid        not null references auth.users(id) on delete restrict,
    app             text        not null,
    app_version     text        not null,
    key_id          text        not null,
    slug            text        not null,
    title           text        not null,
    description     text        not null default '',
    bundle_sha256   text        not null,
    bundle_size     bigint      not null,
    bundle_b64      text        not null,
    status          text        not null default 'received',
    pr_url          text,
    released_in     text,
    maintainer_note text,
    developer_id    text,
    created_at      timestamptz not null default now(),
    updated_at      timestamptz not null default now(),

    constraint chk_app         check (app in ('TradutorBUDA','ScanBUDA')),
    constraint chk_version     check (app_version ~ '^[0-9]+(\.[0-9]+){1,3}$'),
    constraint chk_keyid       check (key_id ~ '^[0-9a-f]{16}$'),
    constraint chk_slug        check (slug ~ '^[a-z0-9][a-z0-9-]{0,59}$'),
    constraint chk_title       check (char_length(title) between 1 and 200),
    constraint chk_desc        check (char_length(description) <= 4000),
    constraint chk_sha256      check (bundle_sha256 ~ '^[0-9a-f]{64}$'),
    constraint chk_size        check (bundle_size > 0),
    constraint chk_status      check (status in ('received','reviewing','pr-opened','merged','declined','released'))
);

create index if not exists fix_sub_sender_idx  on fix_submissions (sender_id);
create index if not exists fix_sub_status_idx  on fix_submissions (status);
create unique index if not exists fix_sub_sha256_uniq on fix_submissions (bundle_sha256);

-- ══════════════════════════════════════════════════════════════════════════════
-- Row-Level Security
-- ══════════════════════════════════════════════════════════════════════════════
alter table fix_submissions      enable row level security;
alter table fix_inbox_developers enable row level security;
alter table fix_inbox_config     enable row level security;

-- Remove políticas antigas antes de recriar (idempotência)
do $$ begin
    drop policy if exists contributor_select on fix_submissions;
    drop policy if exists contributor_insert on fix_submissions;
    drop policy if exists deny_all_developers on fix_inbox_developers;
    drop policy if exists deny_all_config on fix_inbox_config;
end $$;

-- Contribuidor só vê as suas próprias submissões
create policy contributor_select on fix_submissions
    for select
    using (auth.uid() = sender_id);

-- Contribuidor só insere se: é ele mesmo, está registrado, caixa aberta, dentro do limite/hora
create policy contributor_insert on fix_submissions
    for insert
    with check (
        auth.uid() = sender_id
        and exists (
            select 1
            from fix_inbox_developers d
            where d.id     = auth.uid()::text
              and d.active = true
              and d.key_id = fix_submissions.key_id
              and fix_submissions.app = any(d.apps)
        )
        and (select inbox_open   from fix_inbox_config where id = 1) = true
        and (
            select count(*)
            from fix_submissions s2
            where s2.sender_id  = auth.uid()
              and s2.created_at > now() - interval '1 hour'
        ) < (select max_per_hour from fix_inbox_config where id = 1)
    );

-- Ninguém acessa fix_inbox_developers nem fix_inbox_config diretamente
create policy deny_all_developers on fix_inbox_developers for all using (false);
create policy deny_all_config     on fix_inbox_config     for all using (false);

-- ══════════════════════════════════════════════════════════════════════════════
-- Funções de administrador (SECURITY DEFINER — bypassam o RLS)
-- ══════════════════════════════════════════════════════════════════════════════

-- Utilitário interno: valida frase-senha
create or replace function fix_inbox_assert_passphrase(p_passphrase text)
returns void language plpgsql security definer as $$
declare v_hash text; begin
    select passphrase_hash into v_hash from fix_inbox_config where id = 1;
    if v_hash is null or v_hash = '' then
        raise exception 'Caixa não configurada. Execute o INSERT da frase-senha (Passo 1 abaixo).';
    end if;
    if crypt(p_passphrase, v_hash) <> v_hash then
        raise exception 'Frase-senha de administrador incorreta.';
    end if;
end; $$;

-- Lista submissões (sem bundle_b64)
create or replace function fix_inbox_list(p_passphrase text, p_status text default null)
returns table (
    id bigint, app text, app_version text, key_id text, developer_id text,
    slug text, title text, description text, bundle_sha256 text, bundle_size bigint,
    status text, pr_url text, released_in text, maintainer_note text,
    created_at timestamptz, updated_at timestamptz
) language plpgsql security definer as $$
begin
    perform fix_inbox_assert_passphrase(p_passphrase);
    return query
        select s.id, s.app, s.app_version, s.key_id, s.developer_id,
               s.slug, s.title, s.description, s.bundle_sha256, s.bundle_size,
               s.status, s.pr_url, s.released_in, s.maintainer_note,
               s.created_at, s.updated_at
        from fix_submissions s
        where p_status is null or p_status = '' or s.status = p_status
        order by s.created_at desc limit 500;
end; $$;

-- Baixa o bundle (base64) de uma submissão específica
create or replace function fix_inbox_bundle(p_passphrase text, p_id bigint)
returns text language plpgsql security definer as $$
declare v_bundle text; begin
    perform fix_inbox_assert_passphrase(p_passphrase);
    select bundle_b64 into v_bundle from fix_submissions where id = p_id;
    if v_bundle is null then raise exception 'Submissão % não encontrada.', p_id; end if;
    return v_bundle;
end; $$;

-- Atualiza status de uma submissão
create or replace function fix_inbox_set_status(
    p_passphrase text, p_id bigint, p_status text,
    p_pr_url text default null, p_released_in text default null, p_note text default null
)
returns table (id bigint, status text, pr_url text, released_in text, maintainer_note text, updated_at timestamptz)
language plpgsql security definer as $$
begin
    perform fix_inbox_assert_passphrase(p_passphrase);
    if p_status not in ('received','reviewing','pr-opened','merged','declined','released') then
        raise exception 'Status inválido: %', p_status;
    end if;
    return query
        update fix_submissions s set
            status          = p_status,
            pr_url          = coalesce(p_pr_url,      s.pr_url),
            released_in     = coalesce(p_released_in, s.released_in),
            maintainer_note = coalesce(p_note,        s.maintainer_note),
            updated_at      = now()
        where s.id = p_id
        returning s.id, s.status, s.pr_url, s.released_in, s.maintainer_note, s.updated_at;
    if not found then raise exception 'Submissão % não encontrada.', p_id; end if;
end; $$;

-- Registra ou atualiza um desenvolvedor (requer que o usuário já exista em Auth)
create or replace function fix_inbox_register_developer(
    p_passphrase text, p_email text, p_developer_id text, p_key_id text,
    p_public_key text, p_apps text[], p_active boolean default true
)
returns table (id text, email text, developer_id text, key_id text, active boolean, updated_at timestamptz)
language plpgsql security definer as $$
declare v_user_id text; begin
    perform fix_inbox_assert_passphrase(p_passphrase);
    select au.id::text into v_user_id
    from auth.users au where lower(au.email) = lower(p_email) limit 1;
    if v_user_id is null then
        raise exception 'Usuário % não encontrado em Authentication. Convide-o primeiro.', p_email;
    end if;
    insert into fix_inbox_developers (id, email, developer_id, key_id, public_key, apps, active, updated_at)
    values (v_user_id, lower(p_email), p_developer_id, p_key_id, p_public_key, p_apps, p_active, now())
    on conflict (id) do update set
        email = excluded.email, developer_id = excluded.developer_id,
        key_id = excluded.key_id, public_key = excluded.public_key,
        apps = excluded.apps, active = excluded.active, updated_at = now();
    -- Preenche developer_id em submissões anteriores que ficaram sem ele
    update fix_submissions set developer_id = p_developer_id
    where sender_id = v_user_id::uuid and developer_id is null;
    return query select d.id, d.email, d.developer_id, d.key_id, d.active, d.updated_at
                 from fix_inbox_developers d where d.id = v_user_id;
end; $$;

-- Abre ou fecha a caixa e ajusta o limite por hora
create or replace function fix_inbox_set_open(
    p_passphrase text, p_open boolean, p_max_per_hour integer default null
)
returns table (inbox_open boolean, max_per_hour integer, updated_at timestamptz)
language plpgsql security definer as $$
begin
    perform fix_inbox_assert_passphrase(p_passphrase);
    return query
        update fix_inbox_config c set
            inbox_open   = p_open,
            max_per_hour = coalesce(p_max_per_hour, c.max_per_hour),
            updated_at   = now()
        where c.id = 1
        returning c.inbox_open, c.max_per_hour, c.updated_at;
    if not found then
        raise exception 'Configuração não encontrada. Execute o Passo 1 abaixo.';
    end if;
end; $$;

-- Trigger: mantém updated_at atualizado
create or replace function fix_set_updated_at()
returns trigger language plpgsql as $$
begin new.updated_at = now(); return new; end; $$;

drop trigger if exists trg_fix_submissions_upd on fix_submissions;
create trigger trg_fix_submissions_upd
    before update on fix_submissions
    for each row execute function fix_set_updated_at();

-- ══════════════════════════════════════════════════════════════════════════════
-- PRÓXIMOS PASSOS (execute no SQL Editor após este script rodar sem erros)
-- ══════════════════════════════════════════════════════════════════════════════
--
-- PASSO 1 — Definir a frase-senha do mantenedor (faça só uma vez):
--
--   a) Gere o hash:
--        select crypt('minha frase secreta', gen_salt('bf'));
--      Copie o resultado (começa com $2a$...).
--
--   b) Insira a configuração:
--        insert into fix_inbox_config (passphrase_hash)
--        values ('cole-o-hash-aqui');
--
-- PASSO 2 — Configurar o InstaladorBUDA:
--   Supabase → Settings → API:
--   • "Project URL"   → campo "URL do Supabase" no InstaladorBUDA
--   • "anon / public" → campo "Chave publicável" no InstaladorBUDA
--
-- PASSO 3 — Adicionar você como desenvolvedor:
--   a) Supabase → Authentication → Users → "Invite user" (seu e-mail)
--   b) Aceite o convite, defina a senha
--   c) InstaladorBUDA → Sugestões recebidas → Registrar desenvolvedor
--
-- PASSO 4 — Enviar o bundle que já foi criado:
--   InstaladorBUDA → Sugerir mudança → entre com e-mail e senha (passo 3b)
