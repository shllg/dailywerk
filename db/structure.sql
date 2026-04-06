SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET transaction_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;

--
-- Name: pgcrypto; Type: EXTENSION; Schema: -; Owner: -
--

CREATE EXTENSION IF NOT EXISTS pgcrypto WITH SCHEMA public;


--
-- Name: EXTENSION pgcrypto; Type: COMMENT; Schema: -; Owner: -
--

COMMENT ON EXTENSION pgcrypto IS 'cryptographic functions';


--
-- Name: vector; Type: EXTENSION; Schema: -; Owner: -
--

CREATE EXTENSION IF NOT EXISTS vector WITH SCHEMA public;


--
-- Name: EXTENSION vector; Type: COMMENT; Schema: -; Owner: -
--

COMMENT ON EXTENSION vector IS 'vector data type and ivfflat and hnsw access methods';


--
-- Name: gen_random_uuid_v7(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.gen_random_uuid_v7() RETURNS uuid
    LANGUAGE plpgsql
    AS $$
DECLARE
  timestamp_ms bigint;
  value bytea;
  encoded text;
BEGIN
  timestamp_ms := floor(extract(epoch FROM clock_timestamp()) * 1000);
  value := gen_random_bytes(16);

  value := set_byte(value, 0, ((timestamp_ms >> 40) & 255)::integer);
  value := set_byte(value, 1, ((timestamp_ms >> 32) & 255)::integer);
  value := set_byte(value, 2, ((timestamp_ms >> 24) & 255)::integer);
  value := set_byte(value, 3, ((timestamp_ms >> 16) & 255)::integer);
  value := set_byte(value, 4, ((timestamp_ms >> 8) & 255)::integer);
  value := set_byte(value, 5, (timestamp_ms & 255)::integer);

  value := set_byte(value, 6, ((get_byte(value, 6) & 15) | 112)::integer);
  value := set_byte(value, 8, ((get_byte(value, 8) & 63) | 128)::integer);

  encoded := encode(value, 'hex');

  RETURN (
    substr(encoded, 1, 8) || '-' ||
    substr(encoded, 9, 4) || '-' ||
    substr(encoded, 13, 4) || '-' ||
    substr(encoded, 17, 4) || '-' ||
    substr(encoded, 21, 12)
  )::uuid;
END;
$$;


--
-- Name: vault_chunks_tsvector_update(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.vault_chunks_tsvector_update() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  NEW.tsv := to_tsvector('english', coalesce(NEW.content, ''));
  RETURN NEW;
END
$$;


SET default_tablespace = '';

SET default_table_access_method = heap;

--
-- Name: agents; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.agents (
    id uuid DEFAULT public.gen_random_uuid_v7() NOT NULL,
    workspace_id uuid NOT NULL,
    slug character varying NOT NULL,
    name character varying NOT NULL,
    model_id character varying DEFAULT 'gpt-5.4'::character varying NOT NULL,
    instructions text,
    temperature double precision DEFAULT 0.7,
    is_default boolean DEFAULT false NOT NULL,
    active boolean DEFAULT true NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    soul text,
    identity jsonb DEFAULT '{}'::jsonb,
    provider character varying,
    params jsonb DEFAULT '{}'::jsonb,
    thinking jsonb DEFAULT '{}'::jsonb,
    memory_isolation character varying DEFAULT 'shared'::character varying NOT NULL,
    tool_names jsonb DEFAULT '["memory", "vault"]'::jsonb NOT NULL
);

ALTER TABLE ONLY public.agents FORCE ROW LEVEL SECURITY;


--
-- Name: ar_internal_metadata; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.ar_internal_metadata (
    key character varying NOT NULL,
    value character varying,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);


--
-- Name: conversation_archives; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.conversation_archives (
    id uuid DEFAULT public.gen_random_uuid_v7() NOT NULL,
    session_id uuid NOT NULL,
    workspace_id uuid NOT NULL,
    agent_id uuid NOT NULL,
    summary text DEFAULT ''::text NOT NULL,
    key_facts jsonb DEFAULT '[]'::jsonb NOT NULL,
    message_count integer DEFAULT 0 NOT NULL,
    total_tokens integer DEFAULT 0 NOT NULL,
    started_at timestamp(6) without time zone,
    ended_at timestamp(6) without time zone,
    metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    embedding public.vector(1536)
);

ALTER TABLE ONLY public.conversation_archives FORCE ROW LEVEL SECURITY;


--
-- Name: good_job_batches; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.good_job_batches (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    description text,
    serialized_properties jsonb,
    on_finish text,
    on_success text,
    on_discard text,
    callback_queue_name text,
    callback_priority integer,
    enqueued_at timestamp(6) without time zone,
    discarded_at timestamp(6) without time zone,
    finished_at timestamp(6) without time zone,
    jobs_finished_at timestamp(6) without time zone
);


--
-- Name: good_job_executions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.good_job_executions (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    active_job_id uuid NOT NULL,
    job_class text,
    queue_name text,
    serialized_params jsonb,
    scheduled_at timestamp(6) without time zone,
    finished_at timestamp(6) without time zone,
    error text,
    error_event smallint,
    error_backtrace text[],
    process_id uuid,
    duration interval
);


--
-- Name: good_job_processes; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.good_job_processes (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    state jsonb,
    lock_type smallint
);


--
-- Name: good_job_settings; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.good_job_settings (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    key text,
    value jsonb
);


--
-- Name: good_jobs; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.good_jobs (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    queue_name text,
    priority integer,
    serialized_params jsonb,
    scheduled_at timestamp(6) without time zone,
    performed_at timestamp(6) without time zone,
    finished_at timestamp(6) without time zone,
    error text,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    active_job_id uuid,
    concurrency_key text,
    cron_key text,
    retried_good_job_id uuid,
    cron_at timestamp(6) without time zone,
    batch_id uuid,
    batch_callback_id uuid,
    is_discrete boolean,
    executions_count integer,
    job_class text,
    error_event smallint,
    labels text[],
    locked_by_id uuid,
    locked_at timestamp(6) without time zone
);


--
-- Name: memory_entries; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.memory_entries (
    id uuid DEFAULT public.gen_random_uuid_v7() NOT NULL,
    workspace_id uuid NOT NULL,
    agent_id uuid,
    session_id uuid,
    source_message_id uuid,
    category character varying DEFAULT 'fact'::character varying NOT NULL,
    content text NOT NULL,
    source character varying DEFAULT 'system'::character varying NOT NULL,
    importance integer DEFAULT 5 NOT NULL,
    confidence numeric(3,2) DEFAULT 0.7 NOT NULL,
    access_count integer DEFAULT 0 NOT NULL,
    last_accessed_at timestamp(6) without time zone,
    expires_at timestamp(6) without time zone,
    active boolean DEFAULT true NOT NULL,
    fingerprint character varying NOT NULL,
    metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    embedding public.vector(1536),
    staged boolean DEFAULT true NOT NULL,
    promoted_at timestamp(6) without time zone,
    last_decay_at timestamp(6) without time zone
);

ALTER TABLE ONLY public.memory_entries FORCE ROW LEVEL SECURITY;


--
-- Name: memory_entry_versions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.memory_entry_versions (
    id uuid DEFAULT public.gen_random_uuid_v7() NOT NULL,
    memory_entry_id uuid NOT NULL,
    workspace_id uuid NOT NULL,
    session_id uuid,
    editor_user_id uuid,
    editor_agent_id uuid,
    action character varying NOT NULL,
    reason character varying,
    snapshot jsonb DEFAULT '{}'::jsonb NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);

ALTER TABLE ONLY public.memory_entry_versions FORCE ROW LEVEL SECURITY;


--
-- Name: messages; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.messages (
    id uuid DEFAULT public.gen_random_uuid_v7() NOT NULL,
    session_id uuid NOT NULL,
    workspace_id uuid NOT NULL,
    model_id uuid,
    role character varying NOT NULL,
    content text,
    content_raw jsonb,
    thinking_text text,
    thinking_signature text,
    thinking_tokens integer,
    input_tokens integer,
    output_tokens integer,
    cached_tokens integer,
    cache_creation_tokens integer,
    response_id character varying,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    tool_call_id uuid,
    compacted boolean DEFAULT false NOT NULL,
    importance integer,
    media_description text
);

ALTER TABLE ONLY public.messages FORCE ROW LEVEL SECURITY;


--
-- Name: ruby_llm_models; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.ruby_llm_models (
    id uuid DEFAULT public.gen_random_uuid_v7() NOT NULL,
    model_id character varying NOT NULL,
    name character varying NOT NULL,
    provider character varying NOT NULL,
    family character varying,
    model_created_at timestamp(6) without time zone,
    context_window integer,
    max_output_tokens integer,
    knowledge_cutoff date,
    modalities jsonb DEFAULT '{}'::jsonb NOT NULL,
    capabilities jsonb DEFAULT '[]'::jsonb NOT NULL,
    pricing jsonb DEFAULT '{}'::jsonb NOT NULL,
    metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);


--
-- Name: schema_migrations; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.schema_migrations (
    version character varying NOT NULL
);


--
-- Name: sessions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.sessions (
    id uuid DEFAULT public.gen_random_uuid_v7() NOT NULL,
    workspace_id uuid NOT NULL,
    agent_id uuid NOT NULL,
    model_id uuid,
    gateway character varying DEFAULT 'web'::character varying NOT NULL,
    status character varying DEFAULT 'active'::character varying NOT NULL,
    message_count integer DEFAULT 0 NOT NULL,
    total_tokens integer DEFAULT 0 NOT NULL,
    last_activity_at timestamp(6) without time zone,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    summary text,
    title character varying,
    context_data jsonb DEFAULT '{}'::jsonb NOT NULL,
    started_at timestamp(6) without time zone,
    ended_at timestamp(6) without time zone
);

ALTER TABLE ONLY public.sessions FORCE ROW LEVEL SECURITY;


--
-- Name: tool_calls; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.tool_calls (
    id uuid DEFAULT public.gen_random_uuid_v7() NOT NULL,
    message_id uuid NOT NULL,
    tool_call_id character varying NOT NULL,
    name character varying NOT NULL,
    thought_signature text,
    arguments jsonb DEFAULT '{}'::jsonb NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);

ALTER TABLE ONLY public.tool_calls FORCE ROW LEVEL SECURITY;


--
-- Name: user_profiles; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.user_profiles (
    id uuid DEFAULT public.gen_random_uuid_v7() NOT NULL,
    user_id uuid NOT NULL,
    workspace_id uuid NOT NULL,
    synthesized_profile text,
    profile_synthesized_at timestamp(6) without time zone,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);

ALTER TABLE ONLY public.user_profiles FORCE ROW LEVEL SECURITY;


--
-- Name: user_sessions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.user_sessions (
    id uuid DEFAULT public.gen_random_uuid_v7() NOT NULL,
    user_id uuid NOT NULL,
    refresh_token text,
    workos_session_id character varying,
    expires_at timestamp(6) without time zone NOT NULL,
    revoked_at timestamp(6) without time zone,
    ip_address character varying,
    user_agent character varying,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);


--
-- Name: users; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.users (
    id uuid DEFAULT public.gen_random_uuid_v7() NOT NULL,
    email character varying NOT NULL,
    name character varying NOT NULL,
    workos_id character varying,
    status character varying DEFAULT 'active'::character varying NOT NULL,
    settings jsonb DEFAULT '{}'::jsonb NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);


--
-- Name: vault_chunks; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.vault_chunks (
    id uuid DEFAULT public.gen_random_uuid_v7() NOT NULL,
    vault_file_id uuid NOT NULL,
    workspace_id uuid NOT NULL,
    file_path character varying NOT NULL,
    chunk_idx integer NOT NULL,
    content text NOT NULL,
    heading_path character varying,
    metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    tsv tsvector,
    embedding public.vector(1536)
);

ALTER TABLE ONLY public.vault_chunks FORCE ROW LEVEL SECURITY;


--
-- Name: vault_files; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.vault_files (
    id uuid DEFAULT public.gen_random_uuid_v7() NOT NULL,
    vault_id uuid NOT NULL,
    workspace_id uuid NOT NULL,
    path character varying NOT NULL,
    content_hash character varying NOT NULL,
    size_bytes bigint DEFAULT 0 NOT NULL,
    content_type character varying,
    file_type character varying NOT NULL,
    frontmatter jsonb DEFAULT '{}'::jsonb NOT NULL,
    tags character varying[] DEFAULT '{}'::character varying[] NOT NULL,
    title character varying,
    last_modified timestamp(6) without time zone,
    indexed_at timestamp(6) without time zone,
    synced_at timestamp(6) without time zone,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);

ALTER TABLE ONLY public.vault_files FORCE ROW LEVEL SECURITY;


--
-- Name: vault_links; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.vault_links (
    id uuid DEFAULT public.gen_random_uuid_v7() NOT NULL,
    source_id uuid NOT NULL,
    target_id uuid NOT NULL,
    workspace_id uuid NOT NULL,
    link_type character varying NOT NULL,
    link_text character varying,
    context text,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);

ALTER TABLE ONLY public.vault_links FORCE ROW LEVEL SECURITY;


--
-- Name: vaults; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.vaults (
    id uuid DEFAULT public.gen_random_uuid_v7() NOT NULL,
    workspace_id uuid NOT NULL,
    name character varying NOT NULL,
    slug character varying NOT NULL,
    vault_type character varying DEFAULT 'native'::character varying NOT NULL,
    encryption_key_enc text NOT NULL,
    max_size_bytes bigint DEFAULT '2147483648'::bigint NOT NULL,
    current_size_bytes bigint DEFAULT 0 NOT NULL,
    file_count integer DEFAULT 0 NOT NULL,
    status character varying DEFAULT 'active'::character varying NOT NULL,
    error_message text,
    settings jsonb DEFAULT '{}'::jsonb NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);

ALTER TABLE ONLY public.vaults FORCE ROW LEVEL SECURITY;


--
-- Name: workspace_memberships; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.workspace_memberships (
    id uuid DEFAULT public.gen_random_uuid_v7() NOT NULL,
    workspace_id uuid NOT NULL,
    user_id uuid NOT NULL,
    role character varying DEFAULT 'owner'::character varying NOT NULL,
    abilities jsonb DEFAULT '{}'::jsonb NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);


--
-- Name: workspaces; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.workspaces (
    id uuid DEFAULT public.gen_random_uuid_v7() NOT NULL,
    name character varying NOT NULL,
    owner_id uuid NOT NULL,
    settings jsonb DEFAULT '{}'::jsonb NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    workos_organization_id character varying
);


--
-- Name: agents agents_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.agents
    ADD CONSTRAINT agents_pkey PRIMARY KEY (id);


--
-- Name: ar_internal_metadata ar_internal_metadata_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ar_internal_metadata
    ADD CONSTRAINT ar_internal_metadata_pkey PRIMARY KEY (key);


--
-- Name: conversation_archives conversation_archives_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.conversation_archives
    ADD CONSTRAINT conversation_archives_pkey PRIMARY KEY (id);


--
-- Name: good_job_batches good_job_batches_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.good_job_batches
    ADD CONSTRAINT good_job_batches_pkey PRIMARY KEY (id);


--
-- Name: good_job_executions good_job_executions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.good_job_executions
    ADD CONSTRAINT good_job_executions_pkey PRIMARY KEY (id);


--
-- Name: good_job_processes good_job_processes_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.good_job_processes
    ADD CONSTRAINT good_job_processes_pkey PRIMARY KEY (id);


--
-- Name: good_job_settings good_job_settings_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.good_job_settings
    ADD CONSTRAINT good_job_settings_pkey PRIMARY KEY (id);


--
-- Name: good_jobs good_jobs_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.good_jobs
    ADD CONSTRAINT good_jobs_pkey PRIMARY KEY (id);


--
-- Name: memory_entries memory_entries_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.memory_entries
    ADD CONSTRAINT memory_entries_pkey PRIMARY KEY (id);


--
-- Name: memory_entry_versions memory_entry_versions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.memory_entry_versions
    ADD CONSTRAINT memory_entry_versions_pkey PRIMARY KEY (id);


--
-- Name: messages messages_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.messages
    ADD CONSTRAINT messages_pkey PRIMARY KEY (id);


--
-- Name: ruby_llm_models ruby_llm_models_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ruby_llm_models
    ADD CONSTRAINT ruby_llm_models_pkey PRIMARY KEY (id);


--
-- Name: schema_migrations schema_migrations_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.schema_migrations
    ADD CONSTRAINT schema_migrations_pkey PRIMARY KEY (version);


--
-- Name: sessions sessions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.sessions
    ADD CONSTRAINT sessions_pkey PRIMARY KEY (id);


--
-- Name: tool_calls tool_calls_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tool_calls
    ADD CONSTRAINT tool_calls_pkey PRIMARY KEY (id);


--
-- Name: user_profiles user_profiles_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.user_profiles
    ADD CONSTRAINT user_profiles_pkey PRIMARY KEY (id);


--
-- Name: user_sessions user_sessions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.user_sessions
    ADD CONSTRAINT user_sessions_pkey PRIMARY KEY (id);


--
-- Name: users users_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.users
    ADD CONSTRAINT users_pkey PRIMARY KEY (id);


--
-- Name: vault_chunks vault_chunks_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.vault_chunks
    ADD CONSTRAINT vault_chunks_pkey PRIMARY KEY (id);


--
-- Name: vault_files vault_files_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.vault_files
    ADD CONSTRAINT vault_files_pkey PRIMARY KEY (id);


--
-- Name: vault_links vault_links_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.vault_links
    ADD CONSTRAINT vault_links_pkey PRIMARY KEY (id);


--
-- Name: vaults vaults_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.vaults
    ADD CONSTRAINT vaults_pkey PRIMARY KEY (id);


--
-- Name: workspace_memberships workspace_memberships_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.workspace_memberships
    ADD CONSTRAINT workspace_memberships_pkey PRIMARY KEY (id);


--
-- Name: workspaces workspaces_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.workspaces
    ADD CONSTRAINT workspaces_pkey PRIMARY KEY (id);


--
-- Name: idx_conversation_archives_session_unique; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_conversation_archives_session_unique ON public.conversation_archives USING btree (session_id);


--
-- Name: idx_messages_session_active; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_messages_session_active ON public.messages USING btree (session_id) WHERE (compacted = false);


--
-- Name: idx_sessions_active_unique; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_sessions_active_unique ON public.sessions USING btree (workspace_id, agent_id, gateway) WHERE ((status)::text = 'active'::text);


--
-- Name: index_agents_on_workspace_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_agents_on_workspace_id ON public.agents USING btree (workspace_id);


--
-- Name: index_agents_on_workspace_id_and_is_default; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_agents_on_workspace_id_and_is_default ON public.agents USING btree (workspace_id, is_default);


--
-- Name: index_agents_on_workspace_id_and_slug; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_agents_on_workspace_id_and_slug ON public.agents USING btree (workspace_id, slug);


--
-- Name: index_conversation_archives_on_agent_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_conversation_archives_on_agent_id ON public.conversation_archives USING btree (agent_id);


--
-- Name: index_conversation_archives_on_embedding; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_conversation_archives_on_embedding ON public.conversation_archives USING hnsw (embedding public.vector_cosine_ops);


--
-- Name: index_conversation_archives_on_scope; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_conversation_archives_on_scope ON public.conversation_archives USING btree (workspace_id, agent_id, ended_at);


--
-- Name: index_conversation_archives_on_session_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_conversation_archives_on_session_id ON public.conversation_archives USING btree (session_id);


--
-- Name: index_conversation_archives_on_workspace_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_conversation_archives_on_workspace_id ON public.conversation_archives USING btree (workspace_id);


--
-- Name: index_good_job_executions_on_active_job_id_and_created_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_good_job_executions_on_active_job_id_and_created_at ON public.good_job_executions USING btree (active_job_id, created_at);


--
-- Name: index_good_job_executions_on_process_id_and_created_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_good_job_executions_on_process_id_and_created_at ON public.good_job_executions USING btree (process_id, created_at);


--
-- Name: index_good_job_jobs_for_candidate_lookup; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_good_job_jobs_for_candidate_lookup ON public.good_jobs USING btree (priority, created_at) WHERE (finished_at IS NULL);


--
-- Name: index_good_job_settings_on_key; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_good_job_settings_on_key ON public.good_job_settings USING btree (key);


--
-- Name: index_good_jobs_jobs_on_finished_at_only; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_good_jobs_jobs_on_finished_at_only ON public.good_jobs USING btree (finished_at) WHERE (finished_at IS NOT NULL);


--
-- Name: index_good_jobs_jobs_on_priority_created_at_when_unfinished; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_good_jobs_jobs_on_priority_created_at_when_unfinished ON public.good_jobs USING btree (priority DESC NULLS LAST, created_at) WHERE (finished_at IS NULL);


--
-- Name: index_good_jobs_on_active_job_id_and_created_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_good_jobs_on_active_job_id_and_created_at ON public.good_jobs USING btree (active_job_id, created_at);


--
-- Name: index_good_jobs_on_batch_callback_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_good_jobs_on_batch_callback_id ON public.good_jobs USING btree (batch_callback_id) WHERE (batch_callback_id IS NOT NULL);


--
-- Name: index_good_jobs_on_batch_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_good_jobs_on_batch_id ON public.good_jobs USING btree (batch_id) WHERE (batch_id IS NOT NULL);


--
-- Name: index_good_jobs_on_concurrency_key_and_created_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_good_jobs_on_concurrency_key_and_created_at ON public.good_jobs USING btree (concurrency_key, created_at);


--
-- Name: index_good_jobs_on_concurrency_key_when_unfinished; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_good_jobs_on_concurrency_key_when_unfinished ON public.good_jobs USING btree (concurrency_key) WHERE (finished_at IS NULL);


--
-- Name: index_good_jobs_on_cron_key_and_created_at_cond; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_good_jobs_on_cron_key_and_created_at_cond ON public.good_jobs USING btree (cron_key, created_at) WHERE (cron_key IS NOT NULL);


--
-- Name: index_good_jobs_on_cron_key_and_cron_at_cond; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_good_jobs_on_cron_key_and_cron_at_cond ON public.good_jobs USING btree (cron_key, cron_at) WHERE (cron_key IS NOT NULL);


--
-- Name: index_good_jobs_on_job_class; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_good_jobs_on_job_class ON public.good_jobs USING btree (job_class);


--
-- Name: index_good_jobs_on_labels; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_good_jobs_on_labels ON public.good_jobs USING gin (labels) WHERE (labels IS NOT NULL);


--
-- Name: index_good_jobs_on_locked_by_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_good_jobs_on_locked_by_id ON public.good_jobs USING btree (locked_by_id) WHERE (locked_by_id IS NOT NULL);


--
-- Name: index_good_jobs_on_priority_scheduled_at_unfinished_unlocked; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_good_jobs_on_priority_scheduled_at_unfinished_unlocked ON public.good_jobs USING btree (priority, scheduled_at) WHERE ((finished_at IS NULL) AND (locked_by_id IS NULL));


--
-- Name: index_good_jobs_on_queue_name_and_scheduled_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_good_jobs_on_queue_name_and_scheduled_at ON public.good_jobs USING btree (queue_name, scheduled_at) WHERE (finished_at IS NULL);


--
-- Name: index_good_jobs_on_scheduled_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_good_jobs_on_scheduled_at ON public.good_jobs USING btree (scheduled_at) WHERE (finished_at IS NULL);


--
-- Name: index_memory_entries_on_agent_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_memory_entries_on_agent_id ON public.memory_entries USING btree (agent_id);


--
-- Name: index_memory_entries_on_embedding; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_memory_entries_on_embedding ON public.memory_entries USING hnsw (embedding public.vector_cosine_ops);


--
-- Name: index_memory_entries_on_scope; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_memory_entries_on_scope ON public.memory_entries USING btree (workspace_id, agent_id, active);


--
-- Name: index_memory_entries_on_session_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_memory_entries_on_session_id ON public.memory_entries USING btree (session_id);


--
-- Name: index_memory_entries_on_source_message_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_memory_entries_on_source_message_id ON public.memory_entries USING btree (source_message_id);


--
-- Name: index_memory_entries_on_workspace_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_memory_entries_on_workspace_id ON public.memory_entries USING btree (workspace_id);


--
-- Name: index_memory_entries_on_workspace_id_and_active_and_importance; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_memory_entries_on_workspace_id_and_active_and_importance ON public.memory_entries USING btree (workspace_id, active, importance);


--
-- Name: index_memory_entries_on_workspace_id_and_fingerprint; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_memory_entries_on_workspace_id_and_fingerprint ON public.memory_entries USING btree (workspace_id, fingerprint);


--
-- Name: index_memory_entries_on_workspace_staged_importance; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_memory_entries_on_workspace_staged_importance ON public.memory_entries USING btree (workspace_id, staged, importance);


--
-- Name: index_memory_entry_versions_on_editor_agent_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_memory_entry_versions_on_editor_agent_id ON public.memory_entry_versions USING btree (editor_agent_id);


--
-- Name: index_memory_entry_versions_on_editor_user_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_memory_entry_versions_on_editor_user_id ON public.memory_entry_versions USING btree (editor_user_id);


--
-- Name: index_memory_entry_versions_on_memory_entry_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_memory_entry_versions_on_memory_entry_id ON public.memory_entry_versions USING btree (memory_entry_id);


--
-- Name: index_memory_entry_versions_on_memory_entry_id_and_created_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_memory_entry_versions_on_memory_entry_id_and_created_at ON public.memory_entry_versions USING btree (memory_entry_id, created_at);


--
-- Name: index_memory_entry_versions_on_session_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_memory_entry_versions_on_session_id ON public.memory_entry_versions USING btree (session_id);


--
-- Name: index_memory_entry_versions_on_workspace_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_memory_entry_versions_on_workspace_id ON public.memory_entry_versions USING btree (workspace_id);


--
-- Name: index_memory_entry_versions_on_workspace_id_and_created_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_memory_entry_versions_on_workspace_id_and_created_at ON public.memory_entry_versions USING btree (workspace_id, created_at);


--
-- Name: index_messages_on_model_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_messages_on_model_id ON public.messages USING btree (model_id);


--
-- Name: index_messages_on_role; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_messages_on_role ON public.messages USING btree (role);


--
-- Name: index_messages_on_session_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_messages_on_session_id ON public.messages USING btree (session_id);


--
-- Name: index_messages_on_session_id_and_created_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_messages_on_session_id_and_created_at ON public.messages USING btree (session_id, created_at);


--
-- Name: index_messages_on_tool_call_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_messages_on_tool_call_id ON public.messages USING btree (tool_call_id);


--
-- Name: index_messages_on_workspace_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_messages_on_workspace_id ON public.messages USING btree (workspace_id);


--
-- Name: index_ruby_llm_models_on_capabilities; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_ruby_llm_models_on_capabilities ON public.ruby_llm_models USING gin (capabilities);


--
-- Name: index_ruby_llm_models_on_family; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_ruby_llm_models_on_family ON public.ruby_llm_models USING btree (family);


--
-- Name: index_ruby_llm_models_on_modalities; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_ruby_llm_models_on_modalities ON public.ruby_llm_models USING gin (modalities);


--
-- Name: index_ruby_llm_models_on_provider; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_ruby_llm_models_on_provider ON public.ruby_llm_models USING btree (provider);


--
-- Name: index_ruby_llm_models_on_provider_and_model_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_ruby_llm_models_on_provider_and_model_id ON public.ruby_llm_models USING btree (provider, model_id);


--
-- Name: index_sessions_on_agent_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_sessions_on_agent_id ON public.sessions USING btree (agent_id);


--
-- Name: index_sessions_on_model_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_sessions_on_model_id ON public.sessions USING btree (model_id);


--
-- Name: index_sessions_on_workspace_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_sessions_on_workspace_id ON public.sessions USING btree (workspace_id);


--
-- Name: index_sessions_on_workspace_id_and_status; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_sessions_on_workspace_id_and_status ON public.sessions USING btree (workspace_id, status);


--
-- Name: index_tool_calls_on_message_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_tool_calls_on_message_id ON public.tool_calls USING btree (message_id);


--
-- Name: index_tool_calls_on_name; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_tool_calls_on_name ON public.tool_calls USING btree (name);


--
-- Name: index_tool_calls_on_tool_call_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_tool_calls_on_tool_call_id ON public.tool_calls USING btree (tool_call_id);


--
-- Name: index_user_profiles_on_user_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_user_profiles_on_user_id ON public.user_profiles USING btree (user_id);


--
-- Name: index_user_profiles_on_user_id_and_workspace_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_user_profiles_on_user_id_and_workspace_id ON public.user_profiles USING btree (user_id, workspace_id);


--
-- Name: index_user_profiles_on_workspace_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_user_profiles_on_workspace_id ON public.user_profiles USING btree (workspace_id);


--
-- Name: index_user_sessions_on_user_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_user_sessions_on_user_id ON public.user_sessions USING btree (user_id);


--
-- Name: index_user_sessions_on_workos_session_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_user_sessions_on_workos_session_id ON public.user_sessions USING btree (workos_session_id) WHERE (workos_session_id IS NOT NULL);


--
-- Name: index_users_on_email; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_users_on_email ON public.users USING btree (email);


--
-- Name: index_users_on_workos_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_users_on_workos_id ON public.users USING btree (workos_id) WHERE (workos_id IS NOT NULL);


--
-- Name: index_vault_chunks_on_embedding; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_vault_chunks_on_embedding ON public.vault_chunks USING hnsw (embedding public.vector_cosine_ops);


--
-- Name: index_vault_chunks_on_tsv; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_vault_chunks_on_tsv ON public.vault_chunks USING gin (tsv);


--
-- Name: index_vault_chunks_on_vault_file_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_vault_chunks_on_vault_file_id ON public.vault_chunks USING btree (vault_file_id);


--
-- Name: index_vault_chunks_on_vault_file_id_and_chunk_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_vault_chunks_on_vault_file_id_and_chunk_idx ON public.vault_chunks USING btree (vault_file_id, chunk_idx);


--
-- Name: index_vault_chunks_on_workspace_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_vault_chunks_on_workspace_id ON public.vault_chunks USING btree (workspace_id);


--
-- Name: index_vault_chunks_on_workspace_id_and_file_path; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_vault_chunks_on_workspace_id_and_file_path ON public.vault_chunks USING btree (workspace_id, file_path);


--
-- Name: index_vault_files_on_content_hash; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_vault_files_on_content_hash ON public.vault_files USING btree (content_hash);


--
-- Name: index_vault_files_on_tags; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_vault_files_on_tags ON public.vault_files USING gin (tags);


--
-- Name: index_vault_files_on_vault_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_vault_files_on_vault_id ON public.vault_files USING btree (vault_id);


--
-- Name: index_vault_files_on_vault_id_and_path; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_vault_files_on_vault_id_and_path ON public.vault_files USING btree (vault_id, path);


--
-- Name: index_vault_files_on_workspace_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_vault_files_on_workspace_id ON public.vault_files USING btree (workspace_id);


--
-- Name: index_vault_files_on_workspace_id_and_file_type; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_vault_files_on_workspace_id_and_file_type ON public.vault_files USING btree (workspace_id, file_type);


--
-- Name: index_vault_links_on_source_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_vault_links_on_source_id ON public.vault_links USING btree (source_id);


--
-- Name: index_vault_links_on_source_id_and_target_id_and_link_type; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_vault_links_on_source_id_and_target_id_and_link_type ON public.vault_links USING btree (source_id, target_id, link_type);


--
-- Name: index_vault_links_on_target_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_vault_links_on_target_id ON public.vault_links USING btree (target_id);


--
-- Name: index_vault_links_on_workspace_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_vault_links_on_workspace_id ON public.vault_links USING btree (workspace_id);


--
-- Name: index_vault_links_on_workspace_id_and_link_type; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_vault_links_on_workspace_id_and_link_type ON public.vault_links USING btree (workspace_id, link_type);


--
-- Name: index_vaults_on_workspace_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_vaults_on_workspace_id ON public.vaults USING btree (workspace_id);


--
-- Name: index_vaults_on_workspace_id_and_slug; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_vaults_on_workspace_id_and_slug ON public.vaults USING btree (workspace_id, slug);


--
-- Name: index_vaults_on_workspace_id_and_status; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_vaults_on_workspace_id_and_status ON public.vaults USING btree (workspace_id, status);


--
-- Name: index_workspace_memberships_on_user_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_workspace_memberships_on_user_id ON public.workspace_memberships USING btree (user_id);


--
-- Name: index_workspace_memberships_on_workspace_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_workspace_memberships_on_workspace_id ON public.workspace_memberships USING btree (workspace_id);


--
-- Name: index_workspace_memberships_on_workspace_id_and_user_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_workspace_memberships_on_workspace_id_and_user_id ON public.workspace_memberships USING btree (workspace_id, user_id);


--
-- Name: index_workspaces_on_owner_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_workspaces_on_owner_id ON public.workspaces USING btree (owner_id);


--
-- Name: index_workspaces_on_workos_organization_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_workspaces_on_workos_organization_id ON public.workspaces USING btree (workos_organization_id) WHERE (workos_organization_id IS NOT NULL);


--
-- Name: vault_chunks vault_chunks_tsvector_trigger; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER vault_chunks_tsvector_trigger BEFORE INSERT OR UPDATE OF content ON public.vault_chunks FOR EACH ROW EXECUTE FUNCTION public.vault_chunks_tsvector_update();


--
-- Name: memory_entries fk_rails_103a322fcb; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.memory_entries
    ADD CONSTRAINT fk_rails_103a322fcb FOREIGN KEY (source_message_id) REFERENCES public.messages(id);


--
-- Name: user_profiles fk_rails_1c237bcdda; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.user_profiles
    ADD CONSTRAINT fk_rails_1c237bcdda FOREIGN KEY (workspace_id) REFERENCES public.workspaces(id);


--
-- Name: messages fk_rails_1ee2a92df0; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.messages
    ADD CONSTRAINT fk_rails_1ee2a92df0 FOREIGN KEY (session_id) REFERENCES public.sessions(id);


--
-- Name: workspace_memberships fk_rails_26c4c0bd41; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.workspace_memberships
    ADD CONSTRAINT fk_rails_26c4c0bd41 FOREIGN KEY (workspace_id) REFERENCES public.workspaces(id);


--
-- Name: memory_entry_versions fk_rails_2a2bc810a5; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.memory_entry_versions
    ADD CONSTRAINT fk_rails_2a2bc810a5 FOREIGN KEY (editor_user_id) REFERENCES public.users(id);


--
-- Name: memory_entry_versions fk_rails_3a909d5aee; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.memory_entry_versions
    ADD CONSTRAINT fk_rails_3a909d5aee FOREIGN KEY (workspace_id) REFERENCES public.workspaces(id);


--
-- Name: vault_links fk_rails_4351d8fa9b; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.vault_links
    ADD CONSTRAINT fk_rails_4351d8fa9b FOREIGN KEY (target_id) REFERENCES public.vault_files(id) ON DELETE CASCADE;


--
-- Name: workspaces fk_rails_5506b4b37e; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.workspaces
    ADD CONSTRAINT fk_rails_5506b4b37e FOREIGN KEY (owner_id) REFERENCES public.users(id);


--
-- Name: messages fk_rails_552873cb52; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.messages
    ADD CONSTRAINT fk_rails_552873cb52 FOREIGN KEY (tool_call_id) REFERENCES public.tool_calls(id);


--
-- Name: memory_entry_versions fk_rails_6181aa80e3; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.memory_entry_versions
    ADD CONSTRAINT fk_rails_6181aa80e3 FOREIGN KEY (editor_agent_id) REFERENCES public.agents(id);


--
-- Name: vault_links fk_rails_62373dcda0; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.vault_links
    ADD CONSTRAINT fk_rails_62373dcda0 FOREIGN KEY (workspace_id) REFERENCES public.workspaces(id);


--
-- Name: conversation_archives fk_rails_6537030715; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.conversation_archives
    ADD CONSTRAINT fk_rails_6537030715 FOREIGN KEY (session_id) REFERENCES public.sessions(id);


--
-- Name: vault_links fk_rails_72d57f066f; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.vault_links
    ADD CONSTRAINT fk_rails_72d57f066f FOREIGN KEY (source_id) REFERENCES public.vault_files(id) ON DELETE CASCADE;


--
-- Name: conversation_archives fk_rails_7fc7f63642; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.conversation_archives
    ADD CONSTRAINT fk_rails_7fc7f63642 FOREIGN KEY (agent_id) REFERENCES public.agents(id);


--
-- Name: vault_files fk_rails_827af47546; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.vault_files
    ADD CONSTRAINT fk_rails_827af47546 FOREIGN KEY (vault_id) REFERENCES public.vaults(id);


--
-- Name: memory_entry_versions fk_rails_84f6e268a4; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.memory_entry_versions
    ADD CONSTRAINT fk_rails_84f6e268a4 FOREIGN KEY (memory_entry_id) REFERENCES public.memory_entries(id);


--
-- Name: sessions fk_rails_85704b4d26; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.sessions
    ADD CONSTRAINT fk_rails_85704b4d26 FOREIGN KEY (workspace_id) REFERENCES public.workspaces(id);


--
-- Name: user_profiles fk_rails_87a6352e58; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.user_profiles
    ADD CONSTRAINT fk_rails_87a6352e58 FOREIGN KEY (user_id) REFERENCES public.users(id);


--
-- Name: vault_chunks fk_rails_8c1e896a8a; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.vault_chunks
    ADD CONSTRAINT fk_rails_8c1e896a8a FOREIGN KEY (workspace_id) REFERENCES public.workspaces(id);


--
-- Name: memory_entry_versions fk_rails_945aa32c61; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.memory_entry_versions
    ADD CONSTRAINT fk_rails_945aa32c61 FOREIGN KEY (session_id) REFERENCES public.sessions(id);


--
-- Name: tool_calls fk_rails_9c8daee481; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tool_calls
    ADD CONSTRAINT fk_rails_9c8daee481 FOREIGN KEY (message_id) REFERENCES public.messages(id);


--
-- Name: user_sessions fk_rails_9fa262d742; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.user_sessions
    ADD CONSTRAINT fk_rails_9fa262d742 FOREIGN KEY (user_id) REFERENCES public.users(id);


--
-- Name: vault_files fk_rails_a8600483c9; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.vault_files
    ADD CONSTRAINT fk_rails_a8600483c9 FOREIGN KEY (workspace_id) REFERENCES public.workspaces(id);


--
-- Name: sessions fk_rails_aa313d0d16; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.sessions
    ADD CONSTRAINT fk_rails_aa313d0d16 FOREIGN KEY (model_id) REFERENCES public.ruby_llm_models(id);


--
-- Name: conversation_archives fk_rails_aa72fc8b11; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.conversation_archives
    ADD CONSTRAINT fk_rails_aa72fc8b11 FOREIGN KEY (workspace_id) REFERENCES public.workspaces(id);


--
-- Name: workspace_memberships fk_rails_aca847b4f5; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.workspace_memberships
    ADD CONSTRAINT fk_rails_aca847b4f5 FOREIGN KEY (user_id) REFERENCES public.users(id);


--
-- Name: messages fk_rails_b029557475; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.messages
    ADD CONSTRAINT fk_rails_b029557475 FOREIGN KEY (workspace_id) REFERENCES public.workspaces(id);


--
-- Name: sessions fk_rails_beac544c6e; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.sessions
    ADD CONSTRAINT fk_rails_beac544c6e FOREIGN KEY (agent_id) REFERENCES public.agents(id);


--
-- Name: memory_entries fk_rails_bef249fe24; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.memory_entries
    ADD CONSTRAINT fk_rails_bef249fe24 FOREIGN KEY (workspace_id) REFERENCES public.workspaces(id);


--
-- Name: messages fk_rails_c02b47ad97; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.messages
    ADD CONSTRAINT fk_rails_c02b47ad97 FOREIGN KEY (model_id) REFERENCES public.ruby_llm_models(id);


--
-- Name: vaults fk_rails_d1c7090852; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.vaults
    ADD CONSTRAINT fk_rails_d1c7090852 FOREIGN KEY (workspace_id) REFERENCES public.workspaces(id);


--
-- Name: vault_chunks fk_rails_d20f090cb5; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.vault_chunks
    ADD CONSTRAINT fk_rails_d20f090cb5 FOREIGN KEY (vault_file_id) REFERENCES public.vault_files(id);


--
-- Name: memory_entries fk_rails_f9a7923575; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.memory_entries
    ADD CONSTRAINT fk_rails_f9a7923575 FOREIGN KEY (session_id) REFERENCES public.sessions(id);


--
-- Name: agents fk_rails_f9d68ffa97; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.agents
    ADD CONSTRAINT fk_rails_f9d68ffa97 FOREIGN KEY (workspace_id) REFERENCES public.workspaces(id);


--
-- Name: memory_entries fk_rails_ff599837fe; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.memory_entries
    ADD CONSTRAINT fk_rails_ff599837fe FOREIGN KEY (agent_id) REFERENCES public.agents(id);


--
-- Name: agents; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.agents ENABLE ROW LEVEL SECURITY;

--
-- Name: conversation_archives; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.conversation_archives ENABLE ROW LEVEL SECURITY;

--
-- Name: memory_entries; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.memory_entries ENABLE ROW LEVEL SECURITY;

--
-- Name: memory_entry_versions; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.memory_entry_versions ENABLE ROW LEVEL SECURITY;

--
-- Name: messages; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.messages ENABLE ROW LEVEL SECURITY;

--
-- Name: sessions; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.sessions ENABLE ROW LEVEL SECURITY;

--
-- Name: tool_calls; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.tool_calls ENABLE ROW LEVEL SECURITY;

--
-- Name: user_profiles; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.user_profiles ENABLE ROW LEVEL SECURITY;

--
-- Name: vault_chunks; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.vault_chunks ENABLE ROW LEVEL SECURITY;

--
-- Name: vault_files; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.vault_files ENABLE ROW LEVEL SECURITY;

--
-- Name: vault_links; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.vault_links ENABLE ROW LEVEL SECURITY;

--
-- Name: vaults; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.vaults ENABLE ROW LEVEL SECURITY;

--
-- Name: agents workspace_isolation; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY workspace_isolation ON public.agents TO app_user USING (((workspace_id)::text = current_setting('app.current_workspace_id'::text, true))) WITH CHECK (((workspace_id)::text = current_setting('app.current_workspace_id'::text, true)));


--
-- Name: conversation_archives workspace_isolation; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY workspace_isolation ON public.conversation_archives TO app_user USING (((workspace_id)::text = current_setting('app.current_workspace_id'::text, true))) WITH CHECK (((workspace_id)::text = current_setting('app.current_workspace_id'::text, true)));


--
-- Name: memory_entries workspace_isolation; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY workspace_isolation ON public.memory_entries TO app_user USING (((workspace_id)::text = current_setting('app.current_workspace_id'::text, true))) WITH CHECK (((workspace_id)::text = current_setting('app.current_workspace_id'::text, true)));


--
-- Name: memory_entry_versions workspace_isolation; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY workspace_isolation ON public.memory_entry_versions TO app_user USING (((workspace_id)::text = current_setting('app.current_workspace_id'::text, true))) WITH CHECK (((workspace_id)::text = current_setting('app.current_workspace_id'::text, true)));


--
-- Name: messages workspace_isolation; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY workspace_isolation ON public.messages TO app_user USING (((workspace_id)::text = current_setting('app.current_workspace_id'::text, true))) WITH CHECK (((workspace_id)::text = current_setting('app.current_workspace_id'::text, true)));


--
-- Name: sessions workspace_isolation; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY workspace_isolation ON public.sessions TO app_user USING (((workspace_id)::text = current_setting('app.current_workspace_id'::text, true))) WITH CHECK (((workspace_id)::text = current_setting('app.current_workspace_id'::text, true)));


--
-- Name: tool_calls workspace_isolation; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY workspace_isolation ON public.tool_calls TO app_user USING ((EXISTS ( SELECT 1
   FROM public.messages
  WHERE ((messages.id = tool_calls.message_id) AND ((messages.workspace_id)::text = current_setting('app.current_workspace_id'::text, true)))))) WITH CHECK ((EXISTS ( SELECT 1
   FROM public.messages
  WHERE ((messages.id = tool_calls.message_id) AND ((messages.workspace_id)::text = current_setting('app.current_workspace_id'::text, true))))));


--
-- Name: user_profiles workspace_isolation; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY workspace_isolation ON public.user_profiles TO app_user USING (((workspace_id)::text = current_setting('app.current_workspace_id'::text, true))) WITH CHECK (((workspace_id)::text = current_setting('app.current_workspace_id'::text, true)));


--
-- Name: vault_chunks workspace_isolation; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY workspace_isolation ON public.vault_chunks TO app_user USING (((workspace_id)::text = current_setting('app.current_workspace_id'::text, true))) WITH CHECK (((workspace_id)::text = current_setting('app.current_workspace_id'::text, true)));


--
-- Name: vault_files workspace_isolation; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY workspace_isolation ON public.vault_files TO app_user USING (((workspace_id)::text = current_setting('app.current_workspace_id'::text, true))) WITH CHECK (((workspace_id)::text = current_setting('app.current_workspace_id'::text, true)));


--
-- Name: vault_links workspace_isolation; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY workspace_isolation ON public.vault_links TO app_user USING (((workspace_id)::text = current_setting('app.current_workspace_id'::text, true))) WITH CHECK (((workspace_id)::text = current_setting('app.current_workspace_id'::text, true)));


--
-- Name: vaults workspace_isolation; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY workspace_isolation ON public.vaults TO app_user USING (((workspace_id)::text = current_setting('app.current_workspace_id'::text, true))) WITH CHECK (((workspace_id)::text = current_setting('app.current_workspace_id'::text, true)));


--
-- PostgreSQL database dump complete
--

SET search_path TO "$user", public;

INSERT INTO "schema_migrations" (version) VALUES
('20260407000200'),
('20260407000100'),
('20260406203944'),
('20260406203758'),
('20260401110300'),
('20260401110200'),
('20260401110100'),
('20260401110000'),
('20260401100400'),
('20260401100300'),
('20260401100200'),
('20260401100100'),
('20260401100000'),
('20260401090100'),
('20260401090000'),
('20260331100000'),
('20260330100600'),
('20260330100560'),
('20260330100550'),
('20260330100500'),
('20260330100400'),
('20260330100300'),
('20260330100200'),
('20260330100100'),
('20260330100000'),
('20260330090400'),
('20260330090300'),
('20260330090200'),
('20260330090100'),
('20260330090000'),
('20260328003254');

