-- =============================================================================
-- gn_auto_imports : déploiement de la structure (schéma, tables, vues, fonctions)
-- Synchronisation GeoNature distante -> GeoNature locale via l'API du module Export
-- Généré le 2026-11-19 depuis la base d'origine (PostgreSQL 15), découpé le 2026-11-24 :
-- ce script ne contient que le cœur générique. Les modules propres à une source
-- (ex. gn_auto_imports_module_inaturalist.sql) s'installent ensuite.
--
-- Prérequis sur la base cible :
--   * une base GeoNature (gn_meta.t_datasets, ref_geo.l_areas, ref_nomenclatures, gn_synthese...)
--   * extension postgis (fonctions ST_*), dans le search_path des sessions qui lancent la synchro
--   * extension http (pgsql-http) : créée ci-dessous si absente (droits suffisants requis)
--   * le schéma gn_auto_imports ne doit PAS exister (installation neuve)
--
-- Usage :
--   psql -h <hôte> -p <port> -U <user> -d <base> -f gn_auto_imports_deploy_01_structure.sql
--   puis, pour la configuration Bretagne Vivante :
--   psql ... -f gn_auto_imports_deploy_02_config_bretagne_vivante.sql
--   et, pour iNaturalist (module puis configuration) :
--   psql ... -f gn_auto_imports_module_inaturalist.sql
--   psql ... -f gn_auto_imports_deploy_03_config_inaturalist.sql
--
-- Le script s'exécute en une seule transaction : en cas d'erreur, rien n'est créé.
-- Les tables de staging (export_*) et les vues v_<alias>_ready ne sont pas créées ici :
-- elles sont générées automatiquement au premier téléchargement / push.
-- =============================================================================

\set ON_ERROR_STOP on

BEGIN;

CREATE EXTENSION IF NOT EXISTS http SCHEMA public;
CREATE EXTENSION IF NOT EXISTS postgis SCHEMA public;

SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;

--
-- Name: gn_auto_imports; Type: SCHEMA; Schema: -; Owner: -
--

CREATE SCHEMA gn_auto_imports;


--
-- Name: f_api_get(text, jsonb); Type: FUNCTION; Schema: gn_auto_imports; Owner: -
--

CREATE FUNCTION gn_auto_imports.f_api_get(p_url text, p_params jsonb DEFAULT '{}'::jsonb) RETURNS jsonb
    LANGUAGE plpgsql
    AS $$
DECLARE
    r    http_response;
    v_qs text;
    v_url text;
BEGIN
    PERFORM http_set_curlopt('CURLOPT_CONNECTTIMEOUT', '15');
    PERFORM http_set_curlopt('CURLOPT_TIMEOUT', '120');
    -- Certaines API (iNaturalist) demandent d'identifier le client
    PERFORM http_set_curlopt('CURLOPT_USERAGENT', 'gn_auto_imports (GeoNature sync)');

    -- Convertir les paramètres jsonb en query string
    -- Encodage des valeurs : une date '2026-10-19 16:26:08' contient un espace refusé par curl
    SELECT string_agg(urlencode(key) || '=' || urlencode(value), '&' ORDER BY key)
    INTO v_qs
    FROM jsonb_each_text(p_params);

    v_url := CASE WHEN v_qs IS NULL THEN p_url
                  WHEN position('?' IN p_url) > 0 THEN p_url || '&' || v_qs
                  ELSE p_url || '?' || v_qs END;

    r := http_get(v_url);
    IF r.status NOT BETWEEN 200 AND 299 THEN
        -- L'URL est loguée sans les paramètres pour ne pas exposer le token
        RAISE EXCEPTION 'API % : HTTP % : %', p_url, r.status, left(r.content, 300);
    END IF;
    RETURN r.content::jsonb;
END;
$$;


--
-- Name: f_build_ready_view(integer, boolean); Type: FUNCTION; Schema: gn_auto_imports; Owner: -
--

CREATE FUNCTION gn_auto_imports.f_build_ready_view(p_id_terminal integer, p_execute boolean DEFAULT true) RETURNS text
    LANGUAGE plpgsql
    AS $_$
#variable_conflict use_column
DECLARE
    v_mapper    gn_auto_imports.t_mappers%ROWTYPE;
    v_target    regclass;
    v_tschema   text;
    v_ttable    text;
    v_select    text[] := '{}';
    v_joins     text[] := '{}';
    v_dates     text[] := '{}';
    v_view      text;
    v_sql       text;
    v_expr      text;
    v_date_expr text;
    r           record;
BEGIN
    SELECT * INTO v_mapper FROM gn_auto_imports.t_mappers WHERE id_mapper = p_id_terminal;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Mappeur % introuvable', p_id_terminal;
    END IF;
    IF NOT v_mapper.is_terminal THEN
        RAISE EXCEPTION 'Le mappeur % (%) n''est pas terminal', p_id_terminal, v_mapper.alias;
    END IF;
    IF v_mapper.table_name IS NULL THEN
        RAISE EXCEPTION 'Le mappeur % (%) n''a pas de table_name', p_id_terminal, v_mapper.alias;
    END IF;
    IF EXISTS (SELECT 1 FROM gn_auto_imports.f_walk_dependencies(p_id_terminal) w WHERE w.is_cycle) THEN
        RAISE EXCEPTION 'Cycle de dépendances détecté à partir du mappeur %', p_id_terminal;
    END IF;
    IF v_mapper.explode_column IS NOT NULL AND EXISTS (
        SELECT 1 FROM gn_auto_imports.t_mapper_dependencies d
        WHERE d.id_mapper = p_id_terminal AND d.dependency_alias = 'item')
    THEN
        RAISE EXCEPTION 'Mappeur % : l''alias de dépendance "item" est réservé à explode_column', v_mapper.alias;
    END IF;

    -- Table cible (lève une erreur si elle n'existe pas)
    v_target := v_mapper.target_table::regclass;
    SELECT n.nspname, c.relname INTO v_tschema, v_ttable
    FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE c.oid = v_target;

    -- Date de mise à jour du terminal (::timestamptz::timestamp : une date avec fuseau, ex. iNaturalist,
    -- est ramenée à l'heure locale du serveur ; une date sans fuseau est inchangée)
    IF v_mapper.date_filter_source_field IS NOT NULL THEN
        v_dates := v_dates || format('main.%I::timestamptz::timestamp', v_mapper.date_filter_source_field);
    END IF;

    -- Éclatement du tableau JSON : une ligne par élément.
    -- LEFT JOIN : un parent au tableau vide reste présent (item NULL) pour le nettoyage.
    -- Les éléments strictement identiques (doublons côté partenaire) ne donnent qu'une ligne,
    -- à la position de leur première occurrence.
    IF v_mapper.explode_column IS NOT NULL THEN
        v_joins := v_joins || format(
            'LEFT JOIN LATERAL ('
            'SELECT e.value, min(e.idx) AS idx FROM jsonb_array_elements('
            'CASE WHEN jsonb_typeof(NULLIF(main.%1$I::text, '''')::jsonb) = ''array'' '
            'THEN NULLIF(main.%1$I::text, '''')::jsonb ELSE ''[]''::jsonb END'
            ') WITH ORDINALITY AS e(value, idx) GROUP BY e.value'
            ') AS item ON true',
            v_mapper.explode_column);
    END IF;

    -- Jointures vers les dépendances directes
    FOR r IN
        SELECT d.dependency_alias, d.main_join_column, d.dependency_join_column, d.join_type,
               d.contributes_update_date,
               dm.table_name, dm.date_filter_source_field
        FROM gn_auto_imports.t_mapper_dependencies d
        JOIN gn_auto_imports.t_mappers dm ON dm.id_mapper = d.id_mapper_dependency
        WHERE d.id_mapper = p_id_terminal
        ORDER BY d.execution_order, d.dependency_alias
    LOOP
        -- Une dépendance peut être un terminal (ex. filtrer par INNER JOIN sur son staging)
        IF r.table_name IS NULL THEN
            RAISE EXCEPTION 'La dépendance "%" n''a pas de table_name', r.dependency_alias;
        END IF;

        v_joins := v_joins || format(
            '%s JOIN %s AS %I ON %I.%I = main.%I',
            upper(r.join_type),
            gn_auto_imports.f_staging_ref(r.table_name),
            r.dependency_alias,
            r.dependency_alias, r.dependency_join_column,
            r.main_join_column
        );

        IF r.date_filter_source_field IS NOT NULL AND r.contributes_update_date THEN
            v_dates := v_dates || format('%I.%I::timestamptz::timestamp', r.dependency_alias, r.date_filter_source_field);
        END IF;
    END LOOP;

    -- Champs mappés
    FOR r IN
        SELECT f.*,
               (SELECT format_type(a.atttypid, a.atttypmod)
                FROM pg_attribute a
                WHERE a.attrelid = v_target
                  AND a.attname = f.target_column
                  AND a.attnum > 0
                  AND NOT a.attisdropped) AS target_type
        FROM gn_auto_imports.t_mapper_fields f
        WHERE f.id_mapper = p_id_terminal
          AND f.mapping_type <> 'excluded'
        ORDER BY f.id_mapper_field
    LOOP
        -- l'alias source doit être 'main', 'item' (si éclatement) ou une dépendance déclarée
        IF r.mapping_type IN ('direct', 'geom_point', 'geom_geojson')
           AND r.source_alias <> 'main'
           AND NOT (r.source_alias = 'item' AND v_mapper.explode_column IS NOT NULL)
           AND NOT EXISTS (
                SELECT 1 FROM gn_auto_imports.t_mapper_dependencies d
                WHERE d.id_mapper = p_id_terminal AND d.dependency_alias = r.source_alias)
        THEN
            RAISE EXCEPTION 'Champ "%" : alias source "%" inconnu pour ce mappeur', r.target_column, r.source_alias;
        END IF;

        CASE r.mapping_type
            WHEN 'direct' THEN
                IF r.source_column IS NULL THEN
                    RAISE EXCEPTION 'Champ "%" : source_column requis (direct)', r.target_column;
                END IF;
                v_expr := gn_auto_imports.f_source_ref(r.source_alias, r.source_column);

            WHEN 'constant' THEN
                v_expr := format('%L', r.constant_value);

            WHEN 'expression' THEN
                IF r.expression IS NULL THEN
                    RAISE EXCEPTION 'Champ "%" : expression requise', r.target_column;
                END IF;
                v_expr := '(' || r.expression || ')';

            WHEN 'geom_point' THEN
                IF r.source_lon_column IS NULL OR r.source_lat_column IS NULL THEN
                    RAISE EXCEPTION 'Champ "%" : source_lon_column et source_lat_column requis', r.target_column;
                END IF;
                v_expr := format(
                    'ST_Transform(ST_SetSRID(ST_MakePoint(%1$s::double precision, %2$s::double precision), %3$s), Find_SRID(%4$L, %5$L, %6$L))',
                    gn_auto_imports.f_source_ref(r.source_alias, r.source_lon_column),
                    gn_auto_imports.f_source_ref(r.source_alias, r.source_lat_column),
                    COALESCE(r.source_srid, 4326), v_tschema, v_ttable, r.target_column);

            WHEN 'geom_geojson' THEN
                IF r.source_column IS NULL THEN
                    RAISE EXCEPTION 'Champ "%" : source_column requis (geom_geojson)', r.target_column;
                END IF;
                v_expr := format(
                    'ST_Transform(ST_SetSRID(ST_GeomFromGeoJSON(%s::text), %s), Find_SRID(%L, %L, %L))',
                    gn_auto_imports.f_source_ref(r.source_alias, r.source_column),
                    COALESCE(r.source_srid, 4326), v_tschema, v_ttable, r.target_column);
        END CASE;

        -- cast vers le type de la colonne cible (sauf géométries)
        IF r.mapping_type NOT IN ('geom_point', 'geom_geojson') AND r.target_type IS NOT NULL THEN
            v_expr := format('(%s)::%s', v_expr, r.target_type);
        END IF;

        v_select := v_select || format('%s AS %I', v_expr, r.target_column);
    END LOOP;

    IF cardinality(v_select) = 0 THEN
        RAISE EXCEPTION 'Aucun champ mappé pour le mappeur % (%)', p_id_terminal, v_mapper.alias;
    END IF;

    -- Position de l'élément dans le tableau (NULL = parent au tableau vide)
    IF v_mapper.explode_column IS NOT NULL THEN
        v_select := v_select || 'item.idx AS _item_idx'::text;
    END IF;

    -- Clé source brute (indexée dans le staging) : sert au découpage par lots du push
    v_select := v_select || format('main.%I AS _source_key', v_mapper.order_by_column);

    -- Date de mise à jour effective = la plus récente entre le terminal et ses dépendances
    v_date_expr := CASE WHEN cardinality(v_dates) > 0
                        THEN 'GREATEST(' || array_to_string(v_dates, ', ') || ')'
                        ELSE 'NULL::timestamp' END;

    v_view := format('gn_auto_imports.%I', 'v_' || v_mapper.alias || '_ready');

    v_sql := format(
        E'CREATE VIEW %s AS\nSELECT\n  %s,\n  %s AS _source_update_date\nFROM %s AS main\n%s',
        v_view,
        array_to_string(v_select, E',\n  '),
        v_date_expr,
        gn_auto_imports.f_staging_ref(v_mapper.table_name),
        array_to_string(v_joins, E'\n')
    );

    -- Filtre optionnel sur les lignes (condition SQL sur main / item / alias de dépendance)
    IF NULLIF(btrim(v_mapper.row_filter), '') IS NOT NULL THEN
        v_sql := v_sql || E'\nWHERE (' || v_mapper.row_filter || ')';
    END IF;

    IF p_execute THEN
        EXECUTE format('DROP VIEW IF EXISTS %s', v_view);
        EXECUTE v_sql;
    END IF;

    RETURN v_sql;
END;
$_$;


--
-- Name: f_extract_rows(jsonb); Type: FUNCTION; Schema: gn_auto_imports; Owner: -
--

CREATE FUNCTION gn_auto_imports.f_extract_rows(p_payload jsonb) RETURNS jsonb
    LANGUAGE plpgsql IMMUTABLE
    AS $$
DECLARE
    k text;
BEGIN
    IF jsonb_typeof(p_payload) = 'array' THEN
        RETURN p_payload;
    END IF;
    FOREACH k IN ARRAY ARRAY['items', 'data', 'results'] LOOP
        IF p_payload ? k THEN
            RETURN p_payload -> k;
        END IF;
    END LOOP;
    IF p_payload ? 'features' THEN
        RETURN COALESCE(
            (SELECT jsonb_agg(
                        COALESCE(f -> 'properties', '{}'::jsonb)
                        || jsonb_build_object('geometry', f -> 'geometry'))
             FROM jsonb_array_elements(p_payload -> 'features') f),
            '[]'::jsonb);
    END IF;
    RAISE EXCEPTION 'Format de réponse API inconnu : %', left(p_payload::text, 200);
END;
$$;


--
-- Name: f_get_sync_plan(integer); Type: FUNCTION; Schema: gn_auto_imports; Owner: -
--

CREATE FUNCTION gn_auto_imports.f_get_sync_plan(p_id_terminal integer) RETURNS TABLE(step integer, id_mapper integer, alias text, table_name text, is_terminal boolean)
    LANGUAGE plpgsql STABLE
    AS $$
#variable_conflict use_column
BEGIN
    IF NOT EXISTS (SELECT 1 FROM gn_auto_imports.t_mappers m WHERE m.id_mapper = p_id_terminal) THEN
        RAISE EXCEPTION 'Mappeur % introuvable', p_id_terminal;
    END IF;

    IF EXISTS (SELECT 1 FROM gn_auto_imports.f_walk_dependencies(p_id_terminal) w WHERE w.is_cycle) THEN
        RAISE EXCEPTION 'Cycle de dépendances détecté à partir du mappeur %', p_id_terminal;
    END IF;

    RETURN QUERY
    WITH plan AS (
        -- profondeur max : un mappeur partagé par plusieurs branches s'exécute avant tous ses dépendants
        SELECT w.node, max(w.depth) AS depth, min(w.ord) AS ord
        FROM gn_auto_imports.f_walk_dependencies(p_id_terminal) w
        GROUP BY w.node
    )
    SELECT (row_number() OVER (ORDER BY p.depth DESC, p.ord, p.node))::integer,
           m.id_mapper, m.alias, m.table_name, m.is_terminal
    FROM plan p
    JOIN gn_auto_imports.t_mappers m ON m.id_mapper = p.node
    ORDER BY 1;
END;
$$;


--
-- Name: f_push_to_target(integer, text, text, timestamp without time zone, boolean); Type: FUNCTION; Schema: gn_auto_imports; Owner: -
--

CREATE FUNCTION gn_auto_imports.f_push_to_target(p_id_terminal integer, p_key_from text DEFAULT NULL::text, p_key_to text DEFAULT NULL::text, p_wm_max timestamp without time zone DEFAULT NULL::timestamp without time zone, p_build_view boolean DEFAULT true) RETURNS jsonb
    LANGUAGE plpgsql
    AS $_$
#variable_conflict use_column
DECLARE
    t            gn_auto_imports.t_mappers%ROWTYPE;
    v_target     regclass;
    v_keys       text[];
    v_key_cond   text;
    v_key_list   text;
    v_scope_col  text;
    v_scope_val  text;
    v_scope_type text;
    v_scope_cond text := '';
    v_del_col    text;
    v_parent_col text;
    v_view       text;
    v_batch      boolean := p_key_from IS NOT NULL OR p_key_to IS NOT NULL;
    v_filter     text;
    v_cols       text[];
    v_data_cols  text[];
    v_missing    text;
    v_ins_cols   text;
    v_sel_cols   text;
    v_sets       text;
    v_changed    text;
    v_dups       bigint;
    v_new_wm     timestamp;
    v_candidates bigint;
    v_deleted    bigint := 0;
    v_orphans    bigint := 0;
    v_skipped    bigint := 0;
    v_updated    bigint := 0;
    v_inserted   bigint := 0;
    v_step       integer;
    v_t          timestamp := clock_timestamp();
    v_tm         jsonb := '{}'::jsonb;
BEGIN
    SELECT * INTO t FROM gn_auto_imports.t_mappers WHERE id_mapper = p_id_terminal;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Mappeur % introuvable', p_id_terminal;
    END IF;

    v_target     := t.target_table::regclass;
    v_keys       := t.target_key_columns;
    v_scope_col  := t.target_scope_column;
    v_del_col    := t.delete_flag_column;
    v_parent_col := t.target_parent_column;

    -- Condition de correspondance et liste sur la clé (éventuellement composite)
    SELECT string_agg(format('s.%1$I = p.%1$I', k), ' AND ' ORDER BY ord),
           string_agg(format('%I', k), ', ' ORDER BY ord)
    INTO v_key_cond, v_key_list
    FROM unnest(v_keys) WITH ORDINALITY u(k, ord);

    -- Périmètre (ex. id_dataset pour la synthèse) : optionnel
    IF v_scope_col IS NOT NULL THEN
        v_scope_val := COALESCE(t.target_scope_value, t.target_dataset_id::text);
        IF v_scope_val IS NULL THEN
            RAISE EXCEPTION 'Terminal % : valeur de périmètre manquante pour "%" (target_scope_value ou target_dataset_id)',
                t.alias, v_scope_col;
        END IF;
        SELECT format_type(atttypid, atttypmod) INTO v_scope_type
        FROM pg_attribute
        WHERE attrelid = v_target AND attname = v_scope_col AND attnum > 0 AND NOT attisdropped;
        IF v_scope_type IS NULL THEN
            RAISE EXCEPTION 'Terminal % : colonne de périmètre "%" absente de %', t.alias, v_scope_col, v_target;
        END IF;
        v_scope_cond := format(' AND s.%I = $1::%s', v_scope_col, v_scope_type);
    END IF;

    -- Construit (ou recrée) la vue <alias>_ready
    -- (p_build_view = false : vue déjà construite par l'appelant, ex. push par lots)
    -- Push complet : une étape de log à lui ; en mode lot, c'est p_push_to_target qui logue
    IF NOT v_batch THEN
        v_step := gn_auto_imports.f_step_start(p_id_terminal, 'push', '{}'::jsonb);
    END IF;

    IF p_build_view THEN
        PERFORM gn_auto_imports.f_build_ready_view(p_id_terminal);
    END IF;
    v_tm := v_tm || jsonb_build_object('build_s', round(extract(epoch FROM clock_timestamp() - v_t)::numeric, 2));
    v_t  := clock_timestamp();
    v_view := format('gn_auto_imports.%I', 'v_' || t.alias || '_ready');

    -- Table temporaire des candidats : lignes nouvelles ou modifiées depuis le dernier push,
    -- bornées par p_wm_max et restreintes à la plage de clés ]p_key_from, p_key_to] en mode lot
    v_filter := format(
        '(_source_update_date IS NULL '
        ' OR (_source_update_date >= COALESCE(%L::timestamp, ''-infinity''::timestamp)%s))',
        t.last_synthese_push_date,
        CASE WHEN p_wm_max IS NOT NULL
             THEN format(' AND _source_update_date <= %L::timestamp', p_wm_max) ELSE '' END);
    IF p_key_from IS NOT NULL THEN
        v_filter := v_filter || format(' AND _source_key > %L', p_key_from);
    END IF;
    IF p_key_to IS NOT NULL THEN
        v_filter := v_filter || format(' AND _source_key <= %L', p_key_to);
    END IF;

    DROP TABLE IF EXISTS pg_temp._push;
    EXECUTE format(
        'CREATE TEMP TABLE _push ON COMMIT DROP AS '
        'SELECT * FROM %s WHERE %s',
        v_view, v_filter);

    SELECT array_agg(attname::text ORDER BY attnum) INTO v_cols
    FROM pg_attribute
    WHERE attrelid = 'pg_temp._push'::regclass
      AND attnum > 0
      AND NOT attisdropped;

    -- Colonnes écrites : celles de la vue qui existent dans la cible, hors périmètre
    v_data_cols := ARRAY(
        SELECT c FROM unnest(v_cols) WITH ORDINALITY u(c, ord)
        WHERE c NOT IN ('_source_update_date', '_item_idx', '_source_key')
          AND c IS DISTINCT FROM v_scope_col
          AND EXISTS (SELECT 1 FROM pg_attribute a
                      WHERE a.attrelid = v_target AND a.attname = c
                        AND a.attnum > 0 AND NOT a.attisdropped)
        ORDER BY ord);

    SELECT string_agg(k, ', ') INTO v_missing
    FROM unnest(v_keys) k WHERE NOT (k = ANY (v_data_cols));
    IF v_missing IS NOT NULL THEN
        RAISE EXCEPTION 'Terminal % : colonne(s) clé % à mapper dans t_mapper_fields et à faire exister dans %',
            t.alias, v_missing, v_target;
    END IF;
    IF v_parent_col IS NOT NULL AND NOT (v_parent_col = ANY (v_data_cols)) THEN
        RAISE EXCEPTION 'Terminal % : la colonne parent "%" doit être mappée et exister dans %',
            t.alias, v_parent_col, v_target;
    END IF;

    SELECT max(_source_update_date) INTO v_new_wm FROM pg_temp._push;
    v_tm := v_tm || jsonb_build_object('load_s', round(extract(epoch FROM clock_timestamp() - v_t)::numeric, 2));
    v_t  := clock_timestamp();

    -- Nettoyage par parent : lignes cibles d'un parent re-poussé absentes de son tableau
    IF v_parent_col IS NOT NULL THEN
        EXECUTE format(
            'DELETE FROM %1$s s '
            'WHERE s.%2$I IN (SELECT p.%2$I FROM pg_temp._push p WHERE p.%2$I IS NOT NULL)%3$s '
            '  AND NOT EXISTS (SELECT 1 FROM pg_temp._push p '
            '                  WHERE p._item_idx IS NOT NULL AND %4$s)',
            v_target, v_parent_col, v_scope_cond, v_key_cond)
        USING v_scope_val;
        GET DIAGNOSTICS v_orphans = ROW_COUNT;
    END IF;

    -- Parents au tableau vide : servent seulement au nettoyage
    IF '_item_idx' = ANY (v_cols) THEN
        DELETE FROM pg_temp._push WHERE _item_idx IS NULL;
    END IF;

    SELECT count(*) INTO v_candidates FROM pg_temp._push;

    -- Garde-fou : une jointure 1:N (ou un tableau aux éléments identiques) dupliquerait des lignes
    EXECUTE format(
        'SELECT count(*) FROM ('
        '  SELECT 1 FROM pg_temp._push GROUP BY %s HAVING count(*) > 1'
        ') d', v_key_list)
    INTO v_dups;
    IF v_dups > 0 THEN
        RAISE EXCEPTION
            'Terminal % : % clé(s) (%) en double dans la vue',
            t.alias, v_dups, v_key_list;
    END IF;

    -- Clés déjà présentes dans la cible HORS périmètre (ex. même UUID importé à la main dans un
    -- autre JDD) : ni insérées (violation de la contrainte unique) ni modifiées, seulement comptées.
    IF v_scope_col IS NOT NULL THEN
        EXECUTE format(
            'DELETE FROM pg_temp._push p '
            'USING %1$s s '
            'WHERE %2$s AND s.%3$I IS DISTINCT FROM $1::%4$s',
            v_target, v_key_cond, v_scope_col, v_scope_type)
        USING v_scope_val;
        GET DIAGNOSTICS v_skipped = ROW_COUNT;
        IF v_skipped > 0 THEN
            RAISE NOTICE 'Terminal % : % ligne(s) ignorée(s), clé déjà présente dans % hors % = %',
                t.alias, v_skipped, v_target, v_scope_col, v_scope_val;
        END IF;
    END IF;

    -- Suppressions côté partenaire (flag = 'D'), restreintes au périmètre
    IF v_del_col IS NOT NULL AND v_del_col = ANY (v_cols) THEN
        EXECUTE format(
            'DELETE FROM %1$s s '
            'USING pg_temp._push p '
            'WHERE %2$s AND p.%3$I = ''D''%4$s',
            v_target, v_key_cond, v_del_col, v_scope_cond)
        USING v_scope_val;
        GET DIAGNOSTICS v_deleted = ROW_COUNT;
        EXECUTE format('DELETE FROM pg_temp._push WHERE %I = ''D''', v_del_col);
    END IF;

    v_tm := v_tm || jsonb_build_object('delete_s', round(extract(epoch FROM clock_timestamp() - v_t)::numeric, 2));
    v_t  := clock_timestamp();

    -- UPDATE des lignes existantes dans le périmètre
    -- (seules les lignes dont au moins une valeur change sont réécrites : évite de
    --  déclencher pour rien les triggers de la cible, ex. meta_update_date de la synthèse)
    SELECT string_agg(format('%1$I = p.%1$I', c), ', ' ORDER BY ord),
           string_agg(CASE
                          -- types sans opérateur d'égalité : comparaison textuelle
                          WHEN format_type(a.atttypid, NULL) IN ('json', 'xml', 'point', 'line', 'lseg', 'path', 'polygon', 'circle')
                              THEN format('s.%1$I::text IS DISTINCT FROM p.%1$I::text', c)
                          ELSE format('s.%1$I IS DISTINCT FROM p.%1$I', c)
                      END, ' OR ' ORDER BY ord)
    INTO v_sets, v_changed
    FROM unnest(v_data_cols) WITH ORDINALITY u(c, ord)
    JOIN pg_attribute a ON a.attrelid = v_target AND a.attname = u.c AND a.attnum > 0 AND NOT a.attisdropped
    WHERE NOT (c = ANY (v_keys));

    IF v_sets IS NOT NULL THEN
        EXECUTE format(
            'UPDATE %1$s s SET %2$s '
            'FROM pg_temp._push p '
            'WHERE %3$s%4$s AND (%5$s)',
            v_target, v_sets, v_key_cond, v_scope_cond, v_changed)
        USING v_scope_val;
        GET DIAGNOSTICS v_updated = ROW_COUNT;
    END IF;

    v_tm := v_tm || jsonb_build_object('update_s', round(extract(epoch FROM clock_timestamp() - v_t)::numeric, 2));
    v_t  := clock_timestamp();

    -- INSERT des nouvelles lignes (absentes du périmètre)
    SELECT
        string_agg(format('%I',   c), ', ' ORDER BY ord),
        string_agg(format('p.%I', c), ', ' ORDER BY ord)
    INTO v_ins_cols, v_sel_cols
    FROM unnest(v_data_cols) WITH ORDINALITY u(c, ord);

    IF v_scope_col IS NOT NULL THEN
        v_ins_cols := v_ins_cols || format(', %I', v_scope_col);
        v_sel_cols := v_sel_cols || format(', $1::%s', v_scope_type);
    END IF;

    EXECUTE format(
        'INSERT INTO %1$s (%2$s) '
        'SELECT %3$s '
        'FROM pg_temp._push p '
        'WHERE NOT EXISTS ('
        '  SELECT 1 FROM %1$s s '
        '  WHERE %4$s%5$s)',
        v_target, v_ins_cols, v_sel_cols, v_key_cond, v_scope_cond)
    USING v_scope_val;
    GET DIAGNOSTICS v_inserted = ROW_COUNT;
    v_tm := v_tm || jsonb_build_object('insert_s', round(extract(epoch FROM clock_timestamp() - v_t)::numeric, 2));

    -- Repère watermark posé dans la même transaction que le push.
    -- En mode lot, c'est p_push_to_target qui le pose une fois tous les lots passés.
    IF NOT v_batch THEN
        UPDATE gn_auto_imports.t_mappers
        SET last_synthese_push_date = COALESCE(v_new_wm, last_synthese_push_date),
            -- un push complet rend caduc un éventuel push par lots interrompu
            push_cursor             = NULL,
            push_wm_max             = NULL
        WHERE id_mapper = p_id_terminal;
    END IF;

    v_tm := jsonb_build_object(
        'target',     v_target::text,
        'candidates', v_candidates,
        'inserted',   v_inserted,
        'updated',    v_updated,
        'deleted',    v_deleted,
        'orphans_deleted', v_orphans,
        'skipped_other_scope', v_skipped) || v_tm;

    IF NOT v_batch THEN
        PERFORM gn_auto_imports.f_step_update(v_step, 'success', v_candidates, 1, v_tm - 'target');
    END IF;

    RETURN v_tm;
END;
$_$;


--
-- Name: f_source_ref(text, text); Type: FUNCTION; Schema: gn_auto_imports; Owner: -
--

CREATE FUNCTION gn_auto_imports.f_source_ref(p_alias text, p_column text) RETURNS text
    LANGUAGE sql IMMUTABLE
    AS $$
    SELECT CASE
        WHEN p_alias = 'item'
            THEN format('(item.value #>> %L::text[])', string_to_array(p_column, '.')::text)
        ELSE format('%I.%I', p_alias, p_column)
    END;
$$;


--
-- Name: f_staging_ref(text); Type: FUNCTION; Schema: gn_auto_imports; Owner: -
--

CREATE FUNCTION gn_auto_imports.f_staging_ref(p_table_name text) RETURNS text
    LANGUAGE sql IMMUTABLE
    AS $$
    SELECT CASE WHEN position('.' IN p_table_name) > 0
                THEN p_table_name                                   -- déjà qualifié (et quoté) par l'utilisateur
                ELSE format('gn_auto_imports.%I', p_table_name)
           END;
$$;


--
-- Name: f_step_start(integer, text, jsonb); Type: FUNCTION; Schema: gn_auto_imports; Owner: -
--

CREATE FUNCTION gn_auto_imports.f_step_start(p_id_mapper integer, p_step text, p_details jsonb DEFAULT '{}'::jsonb) RETURNS integer
    LANGUAGE sql
    AS $$
    INSERT INTO gn_auto_imports.t_sync_step_log (id_run, id_mapper, step, details)
    VALUES (NULLIF(current_setting('gn_auto_imports.id_run', true), '')::bigint,
            p_id_mapper, p_step, jsonb_strip_nulls(COALESCE(p_details, '{}'::jsonb)))
    RETURNING id_step;
$$;


--
-- Name: f_step_update(integer, text, bigint, integer, jsonb, text); Type: FUNCTION; Schema: gn_auto_imports; Owner: -
--

CREATE FUNCTION gn_auto_imports.f_step_update(p_id_step integer, p_status text, p_rows bigint, p_chunks integer, p_details jsonb DEFAULT '{}'::jsonb, p_error text DEFAULT NULL::text) RETURNS void
    LANGUAGE sql
    AS $$
    UPDATE gn_auto_imports.t_sync_step_log
    SET status        = p_status,
        finished_at   = CASE WHEN p_status = 'running' THEN NULL ELSE clock_timestamp() END,
        n_rows        = p_rows,
        n_chunks      = p_chunks,
        details       = details || jsonb_strip_nulls(COALESCE(p_details, '{}'::jsonb)),
        error_message = p_error
    WHERE id_step = p_id_step;
$$;


--
-- Name: f_walk_dependencies(integer); Type: FUNCTION; Schema: gn_auto_imports; Owner: -
--

CREATE FUNCTION gn_auto_imports.f_walk_dependencies(p_id_terminal integer) RETURNS TABLE(node integer, depth integer, ord integer, is_cycle boolean)
    LANGUAGE sql STABLE
    AS $$
    WITH RECURSIVE walk AS (
        SELECT p_id_terminal AS node,
               ARRAY[p_id_terminal] AS path,
               false AS is_cycle,
               0 AS depth,
               0 AS ord
        UNION ALL
        SELECT d.id_mapper_dependency,
               w.path || d.id_mapper_dependency,
               d.id_mapper_dependency = ANY (w.path),
               w.depth + 1,
               d.execution_order
        FROM walk w
        JOIN gn_auto_imports.t_mapper_dependencies d ON d.id_mapper = w.node
        WHERE NOT w.is_cycle
    )
    SELECT node, depth, ord, is_cycle FROM walk;
$$;


--
-- Name: generate_mapper_fields(integer); Type: PROCEDURE; Schema: gn_auto_imports; Owner: -
--

CREATE PROCEDURE gn_auto_imports.generate_mapper_fields(IN _id_mapper integer)
    LANGUAGE plpgsql
    AS $$
DECLARE
    _mapper RECORD;
    _schema text;
    _table text;
    _tschema text;
    _ttable text;
    _scope_val text;
    _col RECORD;
    _added_count integer := 0;
BEGIN
    SELECT * INTO _mapper FROM gn_auto_imports.t_mappers WHERE id_mapper = _id_mapper;
    _schema := split_part(_mapper.table_name, '.', 1);
    _table  := split_part(_mapper.table_name, '.', 2);

    SELECT n.nspname, c.relname INTO _tschema, _ttable
    FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE c.oid = _mapper.target_table::regclass;

    -- On n'insère QUE les colonnes cibles qui n'ont encore aucun mapping,
    -- qu'il soit manuel ou auto-généré. On ne supprime plus rien ici :
    -- le nettoyage des mappings orphelins est géré par create_type_from_mapper
    -- au moment où une colonne source disparaît.
    -- Les colonnes auto-incrémentées de la cible (serial / identity) sont ignorées.
    FOR _col IN
        SELECT
            src.column_name AS source_column,
            src.data_type AS source_type,
            tgt.column_name AS target_column,
            tgt.data_type AS target_type
        FROM information_schema.columns src
        JOIN information_schema.columns tgt
            ON tgt.table_schema = _tschema
           AND tgt.table_name = _ttable
           AND tgt.column_name = src.column_name
        WHERE src.table_schema = _schema
          AND src.table_name = _table
          AND tgt.is_identity = 'NO'
          AND COALESCE(tgt.column_default, '') NOT LIKE 'nextval(%'
          AND tgt.column_name IS DISTINCT FROM _mapper.target_scope_column
          AND NOT EXISTS (
              SELECT 1 FROM gn_auto_imports.t_mapper_fields mf
              WHERE mf.id_mapper = _id_mapper AND mf.target_column = tgt.column_name
          )
    LOOP
        INSERT INTO gn_auto_imports.t_mapper_fields (
            id_mapper, target_column, mapping_type, source_column, source_srid, is_auto_generated
        )
        VALUES (
            _id_mapper,
            _col.target_column,
            CASE
                WHEN _col.target_column IN ('the_geom_4326','the_geom_point') AND _col.target_type = 'USER-DEFINED'
                    THEN 'geom_geojson'
                ELSE 'direct'
            END,
            _col.source_column,
            CASE WHEN _col.target_column IN ('the_geom_4326','the_geom_point') THEN 4326 ELSE NULL END,
            true
        );
        _added_count := _added_count + 1;
    END LOOP;

    -- Colonne de périmètre (ex. id_dataset) : constante, pas de colonne source correspondante
    _scope_val := COALESCE(_mapper.target_scope_value, _mapper.target_dataset_id::text);
    IF _mapper.target_scope_column IS NOT NULL AND _scope_val IS NOT NULL AND NOT EXISTS (
        SELECT 1 FROM gn_auto_imports.t_mapper_fields
        WHERE id_mapper = _id_mapper AND target_column = _mapper.target_scope_column
    ) THEN
        INSERT INTO gn_auto_imports.t_mapper_fields (
            id_mapper, target_column, mapping_type, constant_value, is_auto_generated
        )
        VALUES (_id_mapper, _mapper.target_scope_column, 'constant', _scope_val, true);
        _added_count := _added_count + 1;
    END IF;

    IF _added_count > 0 THEN
        RAISE NOTICE 'Mapper % : % nouveau(x) mapping(s) auto-généré(s) (colonnes ajoutées côté source ou nouveaux champs cibles)', _mapper.alias, _added_count;
    END IF;
END;
$$;


--
-- Name: p_download_mapper(integer, boolean); Type: PROCEDURE; Schema: gn_auto_imports; Owner: -
--

CREATE PROCEDURE gn_auto_imports.p_download_mapper(IN p_id_mapper integer, IN p_commit_per_page boolean DEFAULT false)
    LANGUAGE plpgsql
    AS $_$
DECLARE
    m          gn_auto_imports.t_mappers%ROWTYPE;
    v_ref      text;
    v_plain    text;
    v_started  timestamp := clock_timestamp();
    v_since    timestamp;
    v_params   jsonb := '{}'::jsonb;
    v_limit    integer;
    v_offset   integer;
    v_rows     jsonb;
    v_n        integer;
    v_cols     text[];
    v_col      text;
    v_collist  text;
    v_defs     text;
    v_sets     text;
    v_conflict text;
    v_total    bigint := 0;
    v_max_id   bigint;
    v_page_max bigint;
    v_mode     text;
    v_step     integer;
    v_pages    integer := 0;
    v_t        timestamp;
    v_api_s    numeric := 0;
    v_db_s     numeric := 0;
BEGIN
    SELECT * INTO m FROM gn_auto_imports.t_mappers WHERE id_mapper = p_id_mapper;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Mappeur % introuvable', p_id_mapper;
    END IF;
    IF m.table_name IS NULL THEN
        RAISE EXCEPTION 'Mappeur % (%) : table_name manquant', p_id_mapper, m.alias;
    END IF;
    IF NOT m.download_enabled THEN
        RAISE NOTICE 'Mappeur % (%) : download_enabled = false, pas de téléchargement', p_id_mapper, m.alias;
        RETURN;
    END IF;

    v_ref   := gn_auto_imports.f_staging_ref(m.table_name);
    v_plain := trim(BOTH '"' FROM regexp_replace(m.table_name, '^.*\.', ''));
    -- Recouvrement de 5 min pour ne pas rater des lignes en cas de décalage horloge
    v_since := m.last_synchronization_date - interval '5 minutes';   -- NULL reste NULL

    -- Créer la table de staging si absente, avec juste la colonne clé
    EXECUTE format('CREATE TABLE IF NOT EXISTS %s (%I text)', v_ref, m.order_by_column);
    -- Index unique sur la clé pour permettre l'upsert
    EXECUTE format(
        'CREATE UNIQUE INDEX IF NOT EXISTS %I ON %s (%I)',
        left('uq_' || v_plain || '_' || m.order_by_column, 63),
        v_ref, m.order_by_column);

    IF m.pagination_mode = 'keyset' AND m.id_filter_query_param IS NULL THEN
        RAISE EXCEPTION 'Mappeur % : la pagination keyset exige id_filter_query_param', m.alias;
    END IF;

    -- Paramètres de requête : fixes (api_params), token, tri, filtre date ou id
    v_params := COALESCE(m.api_params, '{}'::jsonb);
    IF m.token IS NOT NULL THEN
        v_params := v_params || jsonb_build_object('token', m.token);
    END IF;
    IF m.order_param IS NOT NULL THEN
        v_params := v_params || jsonb_build_object(m.order_param, m.order_by_column);
    END IF;
    -- Incrémental (synchro déjà terminée une fois) : filtre sur la date de mise à jour.
    -- Chargement initial (last_synchronization_date NULL, posée seulement en fin de run) :
    -- reprise à partir du dernier id commité.
    IF v_since IS NOT NULL AND m.date_filter_query_param IS NOT NULL THEN
        v_params := v_params || jsonb_build_object(m.date_filter_query_param,
            CASE m.date_filter_format
                -- ISO 8601 avec le fuseau du serveur (ex. 2026-11-19T09:00:00+01:00)
                WHEN 'iso' THEN to_char(v_since::timestamptz, 'YYYY-MM-DD"T"HH24:MI:SSTZH:TZM')
                ELSE v_since::text
            END);
        v_mode := 'incremental';
        RAISE NOTICE '% : téléchargement incrémental, % >= %', m.alias, m.date_filter_query_param, v_since;
    ELSIF m.id_filter_query_param IS NOT NULL AND m.last_imported_id IS NOT NULL THEN
        v_params := v_params || jsonb_build_object(m.id_filter_query_param, m.last_imported_id);
        v_mode := 'reprise_id';
        RAISE NOTICE '% : reprise du chargement initial, % >= %', m.alias, m.id_filter_query_param, m.last_imported_id;
    ELSE
        v_mode := 'complet';
        RAISE NOTICE '% : téléchargement complet', m.alias;
    END IF;

    v_step := gn_auto_imports.f_step_start(p_id_mapper, 'download', jsonb_build_object(
        'mode', v_mode,
        'pagination', m.pagination_mode,
        'filter', CASE v_mode WHEN 'incremental' THEN v_since::text
                              WHEN 'reprise_id'  THEN m.last_imported_id::text END));

    v_limit  := COALESCE(m.max_rows_limit, 1000);
    v_offset := COALESCE(m.starter_index_for_offset, 0);

    LOOP
        -- Délai entre deux requêtes (API limitant le débit, ex. iNaturalist ~1 requête/s)
        IF v_pages > 0 AND COALESCE(m.request_delay_ms, 0) > 0 THEN
            PERFORM pg_sleep(m.request_delay_ms / 1000.0);
        END IF;

        v_t := clock_timestamp();
        v_rows := gn_auto_imports.f_extract_rows(
                      gn_auto_imports.f_api_get(
                          m.url_api,
                          v_params
                          || jsonb_build_object(m.page_size_param, v_limit)
                          -- offset : numéro de page ; keyset : la page suivante est filtrée par id
                          || CASE WHEN m.pagination_mode = 'offset'
                                  THEN jsonb_build_object(m.page_param, v_offset)
                                  ELSE '{}'::jsonb END));

        v_api_s := v_api_s + extract(epoch FROM clock_timestamp() - v_t);
        v_t := clock_timestamp();

        v_n := jsonb_array_length(v_rows);
        EXIT WHEN v_n = 0;

        IF EXISTS (SELECT 1 FROM jsonb_array_elements(v_rows) e
                   WHERE (e ->> m.order_by_column) IS NULL) THEN
            RAISE EXCEPTION '% : ligne sans valeur pour la clé "%"', m.alias, m.order_by_column;
        END IF;

        -- Colonnes présentes dans cette page
        SELECT array_agg(DISTINCT k ORDER BY k) INTO v_cols
        FROM jsonb_array_elements(v_rows) e, jsonb_object_keys(e) k;

        -- Ajouter au staging les colonnes absentes (en text)
        FOR v_col IN
            SELECT c FROM unnest(v_cols) c
            WHERE NOT EXISTS (
                SELECT 1 FROM pg_attribute a
                WHERE a.attrelid = v_ref::regclass
                  AND a.attname = c
                  AND a.attnum > 0
                  AND NOT a.attisdropped)
        LOOP
            EXECUTE format('ALTER TABLE %s ADD COLUMN %I text', v_ref, v_col);
        END LOOP;

        -- Construire les listes de colonnes (collist, defs typées, sets pour ON CONFLICT)
        SELECT
            string_agg(format('%I', a.attname),     ', ' ORDER BY a.attname),
            string_agg(format('%I %s', a.attname, format_type(a.atttypid, a.atttypmod)),
                       ', ' ORDER BY a.attname),
            string_agg(format('%1$I = EXCLUDED.%1$I', a.attname), ', ' ORDER BY a.attname)
                FILTER (WHERE a.attname <> m.order_by_column)
        INTO v_collist, v_defs, v_sets
        FROM pg_attribute a
        WHERE a.attrelid = v_ref::regclass
          AND a.attnum > 0
          AND NOT a.attisdropped
          AND a.attname = ANY (v_cols);

        v_conflict := CASE
            WHEN v_sets IS NULL THEN 'DO NOTHING'
            ELSE 'DO UPDATE SET ' || v_sets
        END;

        EXECUTE format(
            'INSERT INTO %1$s (%2$s) '
            'SELECT DISTINCT ON (%3$I) %2$s '
            'FROM jsonb_to_recordset($1) AS x(%4$s) '
            'ON CONFLICT (%3$I) %5$s',
            v_ref, v_collist, m.order_by_column, v_defs, v_conflict)
        USING v_rows;

        -- Suivre le plus grand id numérique pour last_imported_id
        SELECT max(CASE WHEN (e ->> m.order_by_column) ~ '^[0-9]+$'
                        THEN (e ->> m.order_by_column)::bigint END)
        INTO v_page_max
        FROM jsonb_array_elements(v_rows) e;
        v_max_id := GREATEST(v_max_id, v_page_max);

        -- Point de reprise : enregistré dans la même transaction que les lignes de la page
        IF v_page_max IS NOT NULL THEN
            UPDATE gn_auto_imports.t_mappers
            SET last_imported_id = GREATEST(last_imported_id, v_page_max::integer)
            WHERE id_mapper = p_id_mapper;
        END IF;

        v_total := v_total + v_n;
        v_pages := v_pages + 1;
        v_db_s  := v_db_s + extract(epoch FROM clock_timestamp() - v_t);
        PERFORM gn_auto_imports.f_step_update(v_step, 'running', v_total, v_pages,
            jsonb_build_object('api_s', round(v_api_s, 1), 'db_s', round(v_db_s, 1)));
        RAISE NOTICE '  % : % lignes (cumul %)', m.alias, v_n, v_total;

        IF p_commit_per_page THEN
            COMMIT;
        END IF;

        EXIT WHEN v_n < v_limit;
        IF m.pagination_mode = 'keyset' THEN
            -- Page suivante : ids strictement supérieurs au plus grand id de cette page
            -- (l'API doit trier par id croissant, cf. api_params)
            IF v_page_max IS NULL THEN
                RAISE EXCEPTION '% : pagination keyset impossible, clé "%" non numérique', m.alias, m.order_by_column;
            END IF;
            v_params := v_params || jsonb_build_object(m.id_filter_query_param, v_page_max);
        ELSE
            v_offset := v_offset + 1;    -- numéro de page suivant (convention GeoNature)
        END IF;
    END LOOP;

    UPDATE gn_auto_imports.t_mappers
    SET last_synchronization_date = v_started,
        last_import_date          = now(),
        last_imported_id          = COALESCE(GREATEST(last_imported_id, v_max_id::integer),
                                             v_max_id::integer,
                                             last_imported_id)
    WHERE id_mapper = p_id_mapper;

    PERFORM gn_auto_imports.f_step_update(v_step, 'success', v_total, v_pages,
        jsonb_build_object('api_s', round(v_api_s, 1), 'db_s', round(v_db_s, 1),
                           'last_imported_id', (SELECT last_imported_id FROM gn_auto_imports.t_mappers
                                                WHERE id_mapper = p_id_mapper)));
END;
$_$;


--
-- Name: p_push_to_target(integer, integer, jsonb); Type: PROCEDURE; Schema: gn_auto_imports; Owner: -
--

CREATE PROCEDURE gn_auto_imports.p_push_to_target(IN p_id_terminal integer, IN p_batch_size integer DEFAULT 10000, INOUT p_stats jsonb DEFAULT NULL::jsonb)
    LANGUAGE plpgsql
    AS $$
DECLARE
    t        gn_auto_imports.t_mappers%ROWTYPE;
    v_view   text;
    v_wm_max timestamp;
    v_from   text;
    v_to     text;
    v_total  bigint;
    v_done   bigint := 0;
    v_n      bigint;
    v_lot    integer := 0;
    v_batch  jsonb;
    v_locked boolean := false;
    v_t0     timestamp;
    v_step   integer;
BEGIN
    IF p_batch_size IS NULL OR p_batch_size < 1 THEN
        RAISE EXCEPTION 'p_batch_size doit être un entier positif';
    END IF;

    SELECT * INTO t FROM gn_auto_imports.t_mappers WHERE id_mapper = p_id_terminal;
    IF NOT FOUND OR NOT t.is_terminal THEN
        RAISE EXCEPTION 'Mappeur % introuvable ou non terminal', p_id_terminal;
    END IF;

    -- Verrou de session du terminal (déjà détenu si appelé depuis p_run_terminal)
    IF NOT EXISTS (SELECT 1 FROM pg_locks l
                   WHERE l.locktype = 'advisory' AND l.pid = pg_backend_pid()
                     AND l.classid = 7421 AND l.objid = p_id_terminal AND l.objsubid = 2) THEN
        IF NOT pg_try_advisory_lock(7421, p_id_terminal) THEN
            RAISE NOTICE 'Terminal "%" déjà en cours d''exécution, ignoré', t.alias;
            RETURN;
        END IF;
        v_locked := true;
    END IF;

    PERFORM gn_auto_imports.f_build_ready_view(p_id_terminal);
    v_view := format('gn_auto_imports.%I', 'v_' || t.alias || '_ready');

    IF t.push_cursor IS NULL THEN
        -- Nouveau push : on fige la borne haute du watermark pour toute la durée des lots.
        -- Les lignes modifiées au-delà pendant le push seront reprises au run suivant.
        EXECUTE format(
            'SELECT max(_source_update_date) FROM %s '
            'WHERE _source_update_date >= COALESCE(%L::timestamp, ''-infinity''::timestamp)',
            v_view, t.last_synthese_push_date)
        INTO v_wm_max;
        -- '' = push démarré, aucun lot validé
        UPDATE gn_auto_imports.t_mappers
        SET push_cursor = '', push_wm_max = v_wm_max
        WHERE id_mapper = p_id_terminal;
    ELSE
        -- Reprise d'un push interrompu : même borne, à partir de la dernière clé validée
        v_wm_max := t.push_wm_max;
        v_from   := NULLIF(t.push_cursor, '');
        RAISE NOTICE 'Terminal "%" : reprise du push après la clé %', t.alias, COALESCE(v_from, '(début)');
    END IF;
    v_step := gn_auto_imports.f_step_start(p_id_terminal, 'push', jsonb_build_object(
        'batch_size', p_batch_size, 'resume_from', v_from));
    COMMIT;

    -- Clés candidates restantes (une clé = une ligne du staging, même si elle est éclatée)
    DROP TABLE IF EXISTS pg_temp._push_keys;
    EXECUTE format(
        'CREATE TEMP TABLE _push_keys AS '
        'SELECT DISTINCT _source_key AS k FROM %s '
        'WHERE (_source_update_date IS NULL '
        '       OR (_source_update_date >= COALESCE(%L::timestamp, ''-infinity''::timestamp)%s))%s',
        v_view, t.last_synthese_push_date,
        CASE WHEN v_wm_max IS NOT NULL
             THEN format(' AND _source_update_date <= %L::timestamp', v_wm_max) ELSE '' END,
        CASE WHEN v_from IS NOT NULL
             THEN format(' AND _source_key > %L', v_from) ELSE '' END);
    CREATE INDEX ON pg_temp._push_keys (k);
    ANALYZE pg_temp._push_keys;
    SELECT count(*) INTO v_total FROM pg_temp._push_keys;
    RAISE NOTICE 'Terminal "%" : % clé(s) à pousser par lots de %', t.alias, v_total, p_batch_size;

    p_stats := jsonb_build_object('target', t.target_table, 'candidates', 0, 'inserted', 0,
                                  'updated', 0, 'deleted', 0, 'orphans_deleted', 0);
    LOOP
        SELECT max(k), count(*) INTO v_to, v_n
        FROM (SELECT k FROM pg_temp._push_keys
              WHERE v_from IS NULL OR k > v_from
              ORDER BY k LIMIT p_batch_size) s;
        EXIT WHEN v_n = 0;

        v_t0  := clock_timestamp();
        v_lot := v_lot + 1;
        v_batch := gn_auto_imports.f_push_to_target(p_id_terminal, v_from, v_to, v_wm_max, false);

        -- Cumul des compteurs numériques
        SELECT jsonb_object_agg(key, CASE WHEN jsonb_typeof(value) = 'number'
                                          THEN to_jsonb(value::text::numeric + COALESCE((p_stats ->> key)::numeric, 0))
                                          ELSE value END)
        INTO p_stats
        FROM jsonb_each(v_batch);

        -- Curseur de reprise validé avec le lot
        UPDATE gn_auto_imports.t_mappers SET push_cursor = v_to WHERE id_mapper = p_id_terminal;
        v_done := v_done + v_n;
        PERFORM gn_auto_imports.f_step_update(v_step, 'running', v_done, v_lot, p_stats - 'target');
        COMMIT;

        v_from := v_to;
        RAISE NOTICE '  % : lot % — % / % clés (%) en % s', t.alias, v_lot, v_done, v_total,
            v_batch - 'target', round(extract(epoch FROM clock_timestamp() - v_t0)::numeric, 1);
    END LOOP;

    -- Tous les lots sont passés : watermark posé, curseur effacé
    UPDATE gn_auto_imports.t_mappers
    SET last_synthese_push_date = COALESCE(v_wm_max, last_synthese_push_date),
        push_cursor             = NULL,
        push_wm_max             = NULL
    WHERE id_mapper = p_id_terminal;
    PERFORM gn_auto_imports.f_step_update(v_step, 'success', v_done, v_lot, p_stats - 'target');
    DROP TABLE IF EXISTS pg_temp._push_keys;
    IF v_locked THEN
        PERFORM pg_advisory_unlock(7421, p_id_terminal);
    END IF;
    COMMIT;
END;
$$;


--
-- Name: p_run_all(text); Type: PROCEDURE; Schema: gn_auto_imports; Owner: -
--

CREATE PROCEDURE gn_auto_imports.p_run_all(IN p_alias text DEFAULT NULL::text)
    LANGUAGE plpgsql
    AS $$
DECLARE
    r         record;
    v_done    integer[] := '{}';
    v_started timestamp;
    v_run     bigint;
BEGIN
    FOR r IN
        SELECT id_mapper, alias
        FROM gn_auto_imports.t_mappers
        WHERE is_terminal
          AND active
          AND (p_alias IS NULL OR alias = p_alias)
        ORDER BY id_mapper
    LOOP
        v_started := clock_timestamp();
        v_run     := nextval('gn_auto_imports.t_sync_run_seq');
        BEGIN
            CALL gn_auto_imports.p_run_terminal(r.id_mapper, false, v_done, p_id_run => v_run);
        EXCEPTION WHEN OTHERS THEN
            -- Les verrous de session survivent au rollback ; on libère ceux de la chaîne
            PERFORM pg_advisory_unlock(l.classid::integer, l.objid::integer)
            FROM pg_locks l
            WHERE l.locktype = 'advisory'
              AND l.pid = pg_backend_pid()
              AND l.classid = 7421
              AND l.objsubid = 2;
            -- Log d'erreur — adapté à la structure t_sync_log existante
            INSERT INTO gn_auto_imports.t_sync_log
                (id_run, id_mapper, started_at, finished_at, status, error_message)
            VALUES (v_run, r.id_mapper, v_started, clock_timestamp(), 'error', SQLERRM);
            RAISE WARNING 'Chaîne "%" en échec (terminal non poussé) : %', r.alias, SQLERRM;
        END;
    END LOOP;
END;
$$;


--
-- Name: p_run_terminal(integer, boolean, integer[], integer, bigint); Type: PROCEDURE; Schema: gn_auto_imports; Owner: -
--

CREATE PROCEDURE gn_auto_imports.p_run_terminal(IN p_id_terminal integer, IN p_commit_per_page boolean DEFAULT false, INOUT p_done integer[] DEFAULT '{}'::integer[], IN p_push_batch_size integer DEFAULT NULL::integer, IN p_id_run bigint DEFAULT NULL::bigint)
    LANGUAGE plpgsql
    AS $$
DECLARE
    t             gn_auto_imports.t_mappers%ROWTYPE;
    v_ids         integer[];
    v_terminals   integer[];
    v_locked      integer[] := '{}';
    v_done_before integer[] := p_done;
    v_id          integer;
    v_inactive    text;
    v_alias       text;
    v_started     timestamp := clock_timestamp();
    v_stats       jsonb;
    v_run         bigint := COALESCE(p_id_run, nextval('gn_auto_imports.t_sync_run_seq'));
BEGIN
    SELECT * INTO t FROM gn_auto_imports.t_mappers WHERE id_mapper = p_id_terminal;
    IF NOT FOUND OR NOT t.is_terminal OR NOT t.active THEN
        RAISE EXCEPTION 'Mappeur % introuvable, non terminal ou inactif', p_id_terminal;
    END IF;

    -- Plan d'exécution : lève une exception en cas de cycle de dépendances
    SELECT array_agg(p.id_mapper ORDER BY p.step),
           array_agg(p.id_mapper ORDER BY p.step) FILTER (WHERE p.is_terminal)
    INTO v_ids, v_terminals
    FROM gn_auto_imports.f_get_sync_plan(p_id_terminal) p;

    -- Vérifier que tous les mappeurs de la chaîne sont actifs
    SELECT string_agg(m.alias, ', ') INTO v_inactive
    FROM gn_auto_imports.t_mappers m
    WHERE m.id_mapper = ANY (v_ids) AND NOT m.active;
    IF v_inactive IS NOT NULL THEN
        RAISE EXCEPTION 'Chaîne de "%" : mappeur(s) inactif(s) requis : %', t.alias, v_inactive;
    END IF;

    -- Verrous de session (survivent aux COMMIT) sur tous les terminaux de la chaîne.
    -- Un verrou déjà détenu par cette session (appel direct précédent en échec) est
    -- réutilisé sans être ré-acquis : sinon le compteur de verrou ne redescendrait jamais à 0.
    FOREACH v_id IN ARRAY v_terminals LOOP
        IF EXISTS (SELECT 1 FROM pg_locks l
                   WHERE l.locktype = 'advisory' AND l.pid = pg_backend_pid()
                     AND l.classid = 7421 AND l.objid = v_id AND l.objsubid = 2)
           OR pg_try_advisory_lock(7421, v_id) THEN
            v_locked := v_locked || v_id;
        ELSE
            PERFORM pg_advisory_unlock(7421, x) FROM unnest(v_locked) x;
            RAISE NOTICE 'Chaîne de "%" : terminal % déjà en cours d''exécution, ignoré', t.alias, v_id;
            RETURN;
        END IF;
    END LOOP;

    -- Identifiant du run, lu par les étapes (f_step_start) ; un réglage de session survit aux COMMIT
    PERFORM set_config('gn_auto_imports.id_run', v_run::text, false);
    RAISE NOTICE 'Chaîne de "%" : run %', t.alias, v_run;

    -- Télécharger chaque mappeur de la chaîne (sauf ceux déjà téléchargés ce run)
    FOREACH v_id IN ARRAY v_ids LOOP
        CONTINUE WHEN v_id = ANY (p_done);
        -- Mappeur sans téléchargement propre (relit le staging d'un autre mappeur)
        CONTINUE WHEN NOT (SELECT download_enabled FROM gn_auto_imports.t_mappers WHERE id_mapper = v_id);
        CALL gn_auto_imports.p_download_mapper(v_id, p_commit_per_page);
        p_done := p_done || v_id;
    END LOOP;

    -- Pousser chaque terminal de la chaîne vers sa cible, dépendances d'abord.
    -- Un terminal dépendant déjà traité plus tôt dans ce run (p_done) n'est pas repoussé.
    FOREACH v_id IN ARRAY v_terminals LOOP
        CONTINUE WHEN v_id <> p_id_terminal AND v_id = ANY (v_done_before);

        -- p_push_batch_size renseigné : push par lots avec COMMIT intermédiaires (chargement initial)
        IF p_push_batch_size IS NOT NULL THEN
            v_stats := NULL;
            CALL gn_auto_imports.p_push_to_target(v_id, p_push_batch_size, v_stats);
        ELSE
            v_stats := gn_auto_imports.f_push_to_target(v_id);
        END IF;

        -- Log de succès — adapté à la structure t_sync_log existante
        INSERT INTO gn_auto_imports.t_sync_log
            (id_run, id_mapper, started_at, finished_at, status,
             rows_imported, rows_skipped_other_dataset, rows_deleted)
        VALUES (
            v_run,
            v_id,
            v_started,
            clock_timestamp(),
            'success',
            COALESCE((v_stats->>'inserted')::integer, 0)
                + COALESCE((v_stats->>'updated')::integer, 0),
            COALESCE((v_stats->>'skipped_other_scope')::integer, 0),
            COALESCE((v_stats->>'deleted')::integer, 0)
                + COALESCE((v_stats->>'orphans_deleted')::integer, 0)
        );

        SELECT alias INTO v_alias FROM gn_auto_imports.t_mappers WHERE id_mapper = v_id;
        RAISE NOTICE 'Terminal "%" : %', v_alias, v_stats;

        IF p_commit_per_page THEN
            COMMIT;
        END IF;
    END LOOP;

    PERFORM set_config('gn_auto_imports.id_run', '', false);
    PERFORM pg_advisory_unlock(7421, x) FROM unnest(v_locked) x;
END;
$$;


--
-- Name: t_mapper_dependencies; Type: TABLE; Schema: gn_auto_imports; Owner: -
--

CREATE TABLE gn_auto_imports.t_mapper_dependencies (
    id_mapper integer NOT NULL,
    id_mapper_dependency integer NOT NULL,
    execution_order integer DEFAULT 0 NOT NULL,
    dependency_alias text NOT NULL,
    main_join_column text NOT NULL,
    dependency_join_column text NOT NULL,
    join_type text DEFAULT 'left'::text NOT NULL,
    contributes_update_date boolean DEFAULT true NOT NULL,
    CONSTRAINT dependency_alias_typo CHECK (((dependency_alias ~ '^[a-z][a-z0-9_]*$'::text) AND (dependency_alias <> 'main'::text))),
    CONSTRAINT join_type_check CHECK ((join_type = ANY (ARRAY['left'::text, 'inner'::text]))),
    CONSTRAINT no_self_dependency CHECK ((id_mapper <> id_mapper_dependency))
);


--
-- Name: COLUMN t_mapper_dependencies.contributes_update_date; Type: COMMENT; Schema: gn_auto_imports; Owner: -
--

COMMENT ON COLUMN gn_auto_imports.t_mapper_dependencies.contributes_update_date IS 'La date de mise à jour de la dépendance entre-t-elle dans _source_update_date du mappeur ? (false pour une dépendance servant seulement de filtre)';


--
-- Name: t_mapper_fields; Type: TABLE; Schema: gn_auto_imports; Owner: -
--

CREATE TABLE gn_auto_imports.t_mapper_fields (
    id_mapper_field integer NOT NULL,
    id_mapper integer NOT NULL,
    target_column text NOT NULL,
    mapping_type text DEFAULT 'direct'::text NOT NULL,
    source_column text,
    constant_value text,
    expression text,
    source_srid integer,
    source_lon_column text,
    source_lat_column text,
    is_required boolean DEFAULT false NOT NULL,
    is_auto_generated boolean DEFAULT false NOT NULL,
    source_alias text DEFAULT 'main'::text NOT NULL,
    CONSTRAINT t_mapper_fields_mapping_type_check CHECK ((mapping_type = ANY (ARRAY['direct'::text, 'constant'::text, 'expression'::text, 'geom_point'::text, 'geom_geojson'::text, 'excluded'::text])))
);


--
-- Name: t_mapper_fields_id_mapper_field_seq; Type: SEQUENCE; Schema: gn_auto_imports; Owner: -
--

CREATE SEQUENCE gn_auto_imports.t_mapper_fields_id_mapper_field_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: t_mapper_fields_id_mapper_field_seq; Type: SEQUENCE OWNED BY; Schema: gn_auto_imports; Owner: -
--

ALTER SEQUENCE gn_auto_imports.t_mapper_fields_id_mapper_field_seq OWNED BY gn_auto_imports.t_mapper_fields.id_mapper_field;


--
-- Name: t_mappers; Type: TABLE; Schema: gn_auto_imports; Owner: -
--

CREATE TABLE gn_auto_imports.t_mappers (
    id_mapper integer NOT NULL,
    alias text NOT NULL,
    token text,
    table_name text,
    target_dataset_id integer,
    last_synchronization_date timestamp without time zone,
    active boolean DEFAULT false NOT NULL,
    date_filter_query_param text,
    date_filter_source_field text,
    order_by_column text NOT NULL,
    max_rows_limit integer DEFAULT 1000,
    last_import_date timestamp without time zone,
    last_imported_id integer,
    starter_index_for_offset integer DEFAULT 0 NOT NULL,
    id_filter_query_param text,
    is_terminal boolean DEFAULT true NOT NULL,
    last_synthese_push_date timestamp without time zone,
    url_api text NOT NULL,
    target_table text DEFAULT 'gn_synthese.synthese'::text NOT NULL,
    target_key_columns text[] DEFAULT '{unique_id_sinp}'::text[] NOT NULL,
    target_scope_column text DEFAULT 'id_dataset'::text,
    target_scope_value text,
    delete_flag_column text DEFAULT 'last_action'::text,
    explode_column text,
    target_parent_column text,
    push_cursor text,
    push_wm_max timestamp without time zone,
    row_filter text,
    api_params jsonb DEFAULT '{}'::jsonb NOT NULL,
    pagination_mode text DEFAULT 'offset'::text NOT NULL,
    page_size_param text DEFAULT 'limit'::text NOT NULL,
    page_param text DEFAULT 'offset'::text,
    order_param text DEFAULT 'orderby'::text,
    date_filter_format text DEFAULT 'text'::text NOT NULL,
    request_delay_ms integer DEFAULT 0 NOT NULL,
    download_enabled boolean DEFAULT true NOT NULL,
    CONSTRAINT alias_typo CHECK ((alias ~ '^[a-z][a-z0-9_]+$'::text)),
    CONSTRAINT date_filter_format_check CHECK ((date_filter_format = ANY (ARRAY['text'::text, 'iso'::text]))),
    CONSTRAINT offset_needs_page_param CHECK (((pagination_mode <> 'offset'::text) OR (page_param IS NOT NULL))),
    CONSTRAINT pagination_mode_check CHECK ((pagination_mode = ANY (ARRAY['offset'::text, 'keyset'::text]))),
    CONSTRAINT parent_needs_explode CHECK (((target_parent_column IS NULL) OR (explode_column IS NOT NULL))),
    CONSTRAINT target_key_columns_not_empty CHECK ((cardinality(target_key_columns) > 0)),
    CONSTRAINT terminal_needs_scope_value CHECK (((NOT is_terminal) OR (target_scope_column IS NULL) OR (target_scope_value IS NOT NULL) OR (target_dataset_id IS NOT NULL)))
);


--
-- Name: COLUMN t_mappers.is_terminal; Type: COMMENT; Schema: gn_auto_imports; Owner: -
--

COMMENT ON COLUMN gn_auto_imports.t_mappers.is_terminal IS 'true = alimente la synthèse GeoNature ; false = mappeur intermédiaire (dépendance d''un autre)';


--
-- Name: COLUMN t_mappers.target_table; Type: COMMENT; Schema: gn_auto_imports; Owner: -
--

COMMENT ON COLUMN gn_auto_imports.t_mappers.target_table IS 'Table de destination du push (schema.table)';


--
-- Name: COLUMN t_mappers.target_key_columns; Type: COMMENT; Schema: gn_auto_imports; Owner: -
--

COMMENT ON COLUMN gn_auto_imports.t_mappers.target_key_columns IS 'Colonne(s) clé pour décider INSERT ou UPDATE dans la table cible (clé composite possible)';


--
-- Name: COLUMN t_mappers.target_scope_column; Type: COMMENT; Schema: gn_auto_imports; Owner: -
--

COMMENT ON COLUMN gn_auto_imports.t_mappers.target_scope_column IS 'Colonne limitant UPDATE/DELETE au périmètre du mappeur (NULL = pas de périmètre, correspondance sur la clé seule)';


--
-- Name: COLUMN t_mappers.target_scope_value; Type: COMMENT; Schema: gn_auto_imports; Owner: -
--

COMMENT ON COLUMN gn_auto_imports.t_mappers.target_scope_value IS 'Valeur du périmètre ; à défaut target_dataset_id';


--
-- Name: COLUMN t_mappers.delete_flag_column; Type: COMMENT; Schema: gn_auto_imports; Owner: -
--

COMMENT ON COLUMN gn_auto_imports.t_mappers.delete_flag_column IS 'Colonne de la vue ready signalant une suppression (valeur ''D''), NULL = pas de suppression';


--
-- Name: COLUMN t_mappers.explode_column; Type: COMMENT; Schema: gn_auto_imports; Owner: -
--

COMMENT ON COLUMN gn_auto_imports.t_mappers.explode_column IS 'Colonne du staging contenant un tableau JSON : chaque élément devient une ligne (alias source "item")';


--
-- Name: COLUMN t_mappers.target_parent_column; Type: COMMENT; Schema: gn_auto_imports; Owner: -
--

COMMENT ON COLUMN gn_auto_imports.t_mappers.target_parent_column IS 'Avec explode_column : colonne cible portant l''identifiant du parent. Si renseignée, les lignes cibles d''un parent absentes de son tableau sont SUPPRIMÉES au push (NULL = pas de nettoyage)';


--
-- Name: COLUMN t_mappers.row_filter; Type: COMMENT; Schema: gn_auto_imports; Owner: -
--

COMMENT ON COLUMN gn_auto_imports.t_mappers.row_filter IS 'Condition SQL optionnelle (alias main, item, dépendances) ajoutée en WHERE de la vue v_<alias>_ready';


--
-- Name: COLUMN t_mappers.api_params; Type: COMMENT; Schema: gn_auto_imports; Owner: -
--

COMMENT ON COLUMN gn_auto_imports.t_mappers.api_params IS 'Paramètres de requête fixes envoyés à chaque appel (ex. {"project_id": "276813", "order_by": "id"})';


--
-- Name: COLUMN t_mappers.pagination_mode; Type: COMMENT; Schema: gn_auto_imports; Owner: -
--

COMMENT ON COLUMN gn_auto_imports.t_mappers.pagination_mode IS 'offset = numéro de page dans page_param (GeoNature) ; keyset = page suivante filtrée par id_filter_query_param > plus grand id reçu (API triée par id croissant, ex. iNaturalist id_above)';


--
-- Name: COLUMN t_mappers.page_size_param; Type: COMMENT; Schema: gn_auto_imports; Owner: -
--

COMMENT ON COLUMN gn_auto_imports.t_mappers.page_size_param IS 'Nom du paramètre de taille de page (GeoNature : limit, iNaturalist : per_page)';


--
-- Name: COLUMN t_mappers.page_param; Type: COMMENT; Schema: gn_auto_imports; Owner: -
--

COMMENT ON COLUMN gn_auto_imports.t_mappers.page_param IS 'Nom du paramètre de numéro de page en mode offset (GeoNature : offset)';


--
-- Name: COLUMN t_mappers.order_param; Type: COMMENT; Schema: gn_auto_imports; Owner: -
--

COMMENT ON COLUMN gn_auto_imports.t_mappers.order_param IS 'Nom du paramètre de tri, valeur = order_by_column (GeoNature : orderby) ; NULL = non envoyé (tri fixé dans api_params)';


--
-- Name: COLUMN t_mappers.date_filter_format; Type: COMMENT; Schema: gn_auto_imports; Owner: -
--

COMMENT ON COLUMN gn_auto_imports.t_mappers.date_filter_format IS 'Format de la date du filtre incrémental : text = format PostgreSQL sans fuseau (GeoNature) ; iso = ISO 8601 avec fuseau (iNaturalist)';


--
-- Name: COLUMN t_mappers.request_delay_ms; Type: COMMENT; Schema: gn_auto_imports; Owner: -
--

COMMENT ON COLUMN gn_auto_imports.t_mappers.request_delay_ms IS 'Pause entre deux requêtes API, en millisecondes (iNaturalist : 1000)';

COMMENT ON COLUMN gn_auto_imports.t_mappers.download_enabled IS 'false = pas de téléchargement : le mappeur relit le staging (table_name) d''un autre mappeur, dont il doit dépendre';


--
-- Name: t_mappers_id_mapper_seq; Type: SEQUENCE; Schema: gn_auto_imports; Owner: -
--

CREATE SEQUENCE gn_auto_imports.t_mappers_id_mapper_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: t_mappers_id_mapper_seq; Type: SEQUENCE OWNED BY; Schema: gn_auto_imports; Owner: -
--

ALTER SEQUENCE gn_auto_imports.t_mappers_id_mapper_seq OWNED BY gn_auto_imports.t_mappers.id_mapper;


--
-- Name: t_sync_log; Type: TABLE; Schema: gn_auto_imports; Owner: -
--

CREATE TABLE gn_auto_imports.t_sync_log (
    id_log integer NOT NULL,
    id_mapper integer NOT NULL,
    started_at timestamp without time zone DEFAULT now() NOT NULL,
    finished_at timestamp without time zone,
    status text DEFAULT 'running'::text NOT NULL,
    rows_imported integer,
    error_message text,
    rows_skipped_other_dataset integer,
    rows_deleted integer,
    id_run bigint,
    CONSTRAINT t_sync_log_status_check CHECK ((status = ANY (ARRAY['running'::text, 'success'::text, 'error'::text, 'skipped_incomplete_mapping'::text])))
);


--
-- Name: t_sync_log_id_log_seq; Type: SEQUENCE; Schema: gn_auto_imports; Owner: -
--

CREATE SEQUENCE gn_auto_imports.t_sync_log_id_log_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: t_sync_log_id_log_seq; Type: SEQUENCE OWNED BY; Schema: gn_auto_imports; Owner: -
--

ALTER SEQUENCE gn_auto_imports.t_sync_log_id_log_seq OWNED BY gn_auto_imports.t_sync_log.id_log;


--
-- Name: t_sync_run_seq; Type: SEQUENCE; Schema: gn_auto_imports; Owner: -
--

CREATE SEQUENCE gn_auto_imports.t_sync_run_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: t_sync_step_log; Type: TABLE; Schema: gn_auto_imports; Owner: -
--

CREATE TABLE gn_auto_imports.t_sync_step_log (
    id_step integer NOT NULL,
    id_run bigint,
    id_mapper integer NOT NULL,
    step text NOT NULL,
    started_at timestamp without time zone DEFAULT clock_timestamp() NOT NULL,
    finished_at timestamp without time zone,
    duration interval GENERATED ALWAYS AS ((finished_at - started_at)) STORED,
    status text DEFAULT 'running'::text NOT NULL,
    n_rows bigint,
    n_chunks integer,
    details jsonb DEFAULT '{}'::jsonb NOT NULL,
    error_message text,
    pid integer DEFAULT pg_backend_pid() NOT NULL,
    CONSTRAINT t_sync_step_log_status_check CHECK ((status = ANY (ARRAY['running'::text, 'success'::text, 'error'::text]))),
    CONSTRAINT t_sync_step_log_step_check CHECK ((step = ANY (ARRAY['download'::text, 'push'::text])))
);


--
-- Name: t_sync_step_log_id_step_seq; Type: SEQUENCE; Schema: gn_auto_imports; Owner: -
--

CREATE SEQUENCE gn_auto_imports.t_sync_step_log_id_step_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: t_sync_step_log_id_step_seq; Type: SEQUENCE OWNED BY; Schema: gn_auto_imports; Owner: -
--

ALTER SEQUENCE gn_auto_imports.t_sync_step_log_id_step_seq OWNED BY gn_auto_imports.t_sync_step_log.id_step;


--
-- Name: v_mapping_report; Type: VIEW; Schema: gn_auto_imports; Owner: -
--

CREATE VIEW gn_auto_imports.v_mapping_report AS
 SELECT m.id_mapper,
    m.alias,
    src.column_name AS source_column,
    mf.target_column,
        CASE
            WHEN (mf.id_mapper_field IS NULL) THEN 'non mappé'::text
            ELSE mf.mapping_type
        END AS statut
   FROM ((gn_auto_imports.t_mappers m
     JOIN information_schema.columns src ON ((((src.table_schema)::name = split_part(m.table_name, '.'::text, 1)) AND ((src.table_name)::name = split_part(m.table_name, '.'::text, 2)))))
     LEFT JOIN gn_auto_imports.t_mapper_fields mf ON (((mf.id_mapper = m.id_mapper) AND (mf.source_column = (src.column_name)::name))));


--
-- Name: v_missing_required_fields; Type: VIEW; Schema: gn_auto_imports; Owner: -
--

CREATE VIEW gn_auto_imports.v_missing_required_fields AS
 SELECT m.id_mapper,
    m.alias,
    tgt.column_name AS target_column
   FROM ((gn_auto_imports.t_mappers m
     JOIN information_schema.columns tgt ON ((((tgt.table_schema)::name = split_part(m.target_table, '.'::text, 1)) AND ((tgt.table_name)::name = split_part(m.target_table, '.'::text, 2)) AND ((tgt.is_nullable)::text = 'NO'::text) AND (tgt.column_default IS NULL))))
     LEFT JOIN gn_auto_imports.t_mapper_fields mf ON (((mf.id_mapper = m.id_mapper) AND (mf.target_column = (tgt.column_name)::name))))
  WHERE ((mf.id_mapper_field IS NULL) AND ((tgt.column_name)::text IS DISTINCT FROM m.target_scope_column));


--
-- Name: v_sync_alerts; Type: VIEW; Schema: gn_auto_imports; Owner: -
--

CREATE VIEW gn_auto_imports.v_sync_alerts AS
 SELECT t_sync_log.id_mapper,
    t_sync_log.started_at,
    t_sync_log.status,
    t_sync_log.rows_imported,
    t_sync_log.rows_skipped_other_dataset
   FROM gn_auto_imports.t_sync_log
  WHERE ((t_sync_log.rows_skipped_other_dataset > 0) OR (t_sync_log.status = ANY (ARRAY['error'::text, 'skipped_incomplete_mapping'::text])))
  ORDER BY t_sync_log.started_at DESC;


--
-- Name: v_sync_steps; Type: VIEW; Schema: gn_auto_imports; Owner: -
--

CREATE VIEW gn_auto_imports.v_sync_steps AS
 SELECT s.id_run,
    s.id_step,
    m.alias,
    s.step,
    s.started_at,
    s.finished_at,
    COALESCE(s.duration, ((clock_timestamp())::timestamp without time zone - s.started_at)) AS duration,
        CASE
            WHEN ((s.status = 'running'::text) AND (NOT (EXISTS ( SELECT 1
               FROM pg_stat_activity a
              WHERE ((a.pid = s.pid) AND ((a.backend_start)::timestamp without time zone <= s.started_at)))))) THEN 'interrupted'::text
            ELSE s.status
        END AS status,
    s.n_rows,
    s.n_chunks,
    round(((s.n_rows)::numeric / NULLIF(EXTRACT(epoch FROM COALESCE(s.duration, ((clock_timestamp())::timestamp without time zone - s.started_at))), (0)::numeric))) AS rows_per_s,
    s.details,
    s.error_message
   FROM (gn_auto_imports.t_sync_step_log s
     JOIN gn_auto_imports.t_mappers m USING (id_mapper));


--
-- Name: v_sync_runs; Type: VIEW; Schema: gn_auto_imports; Owner: -
--

CREATE VIEW gn_auto_imports.v_sync_runs AS
 SELECT v_sync_steps.id_run,
    v_sync_steps.alias,
    min(v_sync_steps.started_at) AS started_at,
    max(v_sync_steps.finished_at) AS finished_at,
    sum(v_sync_steps.duration) FILTER (WHERE (v_sync_steps.step = 'download'::text)) AS download_duration,
    sum(v_sync_steps.n_rows) FILTER (WHERE (v_sync_steps.step = 'download'::text)) AS rows_downloaded,
    sum(((v_sync_steps.details ->> 'api_s'::text))::numeric) FILTER (WHERE (v_sync_steps.step = 'download'::text)) AS download_api_s,
    sum(v_sync_steps.duration) FILTER (WHERE (v_sync_steps.step = 'push'::text)) AS push_duration,
    sum(((v_sync_steps.details ->> 'candidates'::text))::numeric) FILTER (WHERE (v_sync_steps.step = 'push'::text)) AS push_candidates,
    sum(((v_sync_steps.details ->> 'inserted'::text))::numeric) FILTER (WHERE (v_sync_steps.step = 'push'::text)) AS pushed_inserted,
    sum(((v_sync_steps.details ->> 'updated'::text))::numeric) FILTER (WHERE (v_sync_steps.step = 'push'::text)) AS pushed_updated,
    string_agg(DISTINCT v_sync_steps.status, ', '::text) AS statuses
   FROM gn_auto_imports.v_sync_steps
  GROUP BY v_sync_steps.id_run, v_sync_steps.alias;


--
-- Name: t_mapper_fields id_mapper_field; Type: DEFAULT; Schema: gn_auto_imports; Owner: -
--

ALTER TABLE ONLY gn_auto_imports.t_mapper_fields ALTER COLUMN id_mapper_field SET DEFAULT nextval('gn_auto_imports.t_mapper_fields_id_mapper_field_seq'::regclass);


--
-- Name: t_mappers id_mapper; Type: DEFAULT; Schema: gn_auto_imports; Owner: -
--

ALTER TABLE ONLY gn_auto_imports.t_mappers ALTER COLUMN id_mapper SET DEFAULT nextval('gn_auto_imports.t_mappers_id_mapper_seq'::regclass);


--
-- Name: t_sync_log id_log; Type: DEFAULT; Schema: gn_auto_imports; Owner: -
--

ALTER TABLE ONLY gn_auto_imports.t_sync_log ALTER COLUMN id_log SET DEFAULT nextval('gn_auto_imports.t_sync_log_id_log_seq'::regclass);


--
-- Name: t_sync_step_log id_step; Type: DEFAULT; Schema: gn_auto_imports; Owner: -
--

ALTER TABLE ONLY gn_auto_imports.t_sync_step_log ALTER COLUMN id_step SET DEFAULT nextval('gn_auto_imports.t_sync_step_log_id_step_seq'::regclass);


--
-- Name: t_mapper_dependencies dependency_alias_unique; Type: CONSTRAINT; Schema: gn_auto_imports; Owner: -
--

ALTER TABLE ONLY gn_auto_imports.t_mapper_dependencies
    ADD CONSTRAINT dependency_alias_unique UNIQUE (id_mapper, dependency_alias);


--
-- Name: t_mapper_dependencies t_mapper_dependencies_pkey; Type: CONSTRAINT; Schema: gn_auto_imports; Owner: -
--

ALTER TABLE ONLY gn_auto_imports.t_mapper_dependencies
    ADD CONSTRAINT t_mapper_dependencies_pkey PRIMARY KEY (id_mapper, id_mapper_dependency);


--
-- Name: t_mapper_fields t_mapper_fields_id_mapper_target_column_key; Type: CONSTRAINT; Schema: gn_auto_imports; Owner: -
--

ALTER TABLE ONLY gn_auto_imports.t_mapper_fields
    ADD CONSTRAINT t_mapper_fields_id_mapper_target_column_key UNIQUE (id_mapper, target_column);


--
-- Name: t_mapper_fields t_mapper_fields_pkey; Type: CONSTRAINT; Schema: gn_auto_imports; Owner: -
--

ALTER TABLE ONLY gn_auto_imports.t_mapper_fields
    ADD CONSTRAINT t_mapper_fields_pkey PRIMARY KEY (id_mapper_field);


--
-- Name: t_mappers t_mappings_alias_key; Type: CONSTRAINT; Schema: gn_auto_imports; Owner: -
--

ALTER TABLE ONLY gn_auto_imports.t_mappers
    ADD CONSTRAINT t_mappings_alias_key UNIQUE (alias);


--
-- Name: t_mappers t_mappings_pkey; Type: CONSTRAINT; Schema: gn_auto_imports; Owner: -
--

ALTER TABLE ONLY gn_auto_imports.t_mappers
    ADD CONSTRAINT t_mappings_pkey PRIMARY KEY (id_mapper);


--
-- Name: t_sync_log t_sync_log_pkey; Type: CONSTRAINT; Schema: gn_auto_imports; Owner: -
--

ALTER TABLE ONLY gn_auto_imports.t_sync_log
    ADD CONSTRAINT t_sync_log_pkey PRIMARY KEY (id_log);


--
-- Name: t_sync_step_log t_sync_step_log_pkey; Type: CONSTRAINT; Schema: gn_auto_imports; Owner: -
--

ALTER TABLE ONLY gn_auto_imports.t_sync_step_log
    ADD CONSTRAINT t_sync_step_log_pkey PRIMARY KEY (id_step);


--
-- Name: t_mappers table_name_required; Type: CHECK CONSTRAINT; Schema: gn_auto_imports; Owner: -
--

ALTER TABLE gn_auto_imports.t_mappers
    ADD CONSTRAINT table_name_required CHECK ((table_name IS NOT NULL)) NOT VALID;


--
-- Name: i_t_sync_step_log_mapper; Type: INDEX; Schema: gn_auto_imports; Owner: -
--

CREATE INDEX i_t_sync_step_log_mapper ON gn_auto_imports.t_sync_step_log USING btree (id_mapper, started_at DESC);


--
-- Name: i_t_sync_step_log_run; Type: INDEX; Schema: gn_auto_imports; Owner: -
--

CREATE INDEX i_t_sync_step_log_run ON gn_auto_imports.t_sync_step_log USING btree (id_run);


--
-- Name: t_mapper_dependencies t_mapper_dependencies_dependency_fkey; Type: FK CONSTRAINT; Schema: gn_auto_imports; Owner: -
--

ALTER TABLE ONLY gn_auto_imports.t_mapper_dependencies
    ADD CONSTRAINT t_mapper_dependencies_dependency_fkey FOREIGN KEY (id_mapper_dependency) REFERENCES gn_auto_imports.t_mappers(id_mapper) ON DELETE RESTRICT;


--
-- Name: t_mapper_dependencies t_mapper_dependencies_mapper_fkey; Type: FK CONSTRAINT; Schema: gn_auto_imports; Owner: -
--

ALTER TABLE ONLY gn_auto_imports.t_mapper_dependencies
    ADD CONSTRAINT t_mapper_dependencies_mapper_fkey FOREIGN KEY (id_mapper) REFERENCES gn_auto_imports.t_mappers(id_mapper) ON DELETE CASCADE;


--
-- Name: t_mapper_fields t_mapper_fields_id_mapper_fkey; Type: FK CONSTRAINT; Schema: gn_auto_imports; Owner: -
--

ALTER TABLE ONLY gn_auto_imports.t_mapper_fields
    ADD CONSTRAINT t_mapper_fields_id_mapper_fkey FOREIGN KEY (id_mapper) REFERENCES gn_auto_imports.t_mappers(id_mapper) ON DELETE CASCADE;


--
-- Name: t_mappers t_mappers_target_dataset_id_fkey; Type: FK CONSTRAINT; Schema: gn_auto_imports; Owner: -
--

ALTER TABLE ONLY gn_auto_imports.t_mappers
    ADD CONSTRAINT t_mappers_target_dataset_id_fkey FOREIGN KEY (target_dataset_id) REFERENCES gn_meta.t_datasets(id_dataset);


--
-- Name: t_sync_log t_sync_log_id_mapper_fkey; Type: FK CONSTRAINT; Schema: gn_auto_imports; Owner: -
--

ALTER TABLE ONLY gn_auto_imports.t_sync_log
    ADD CONSTRAINT t_sync_log_id_mapper_fkey FOREIGN KEY (id_mapper) REFERENCES gn_auto_imports.t_mappers(id_mapper) ON DELETE CASCADE;


--
-- Name: t_sync_step_log t_sync_step_log_id_mapper_fkey; Type: FK CONSTRAINT; Schema: gn_auto_imports; Owner: -
--

ALTER TABLE ONLY gn_auto_imports.t_sync_step_log
    ADD CONSTRAINT t_sync_step_log_id_mapper_fkey FOREIGN KEY (id_mapper) REFERENCES gn_auto_imports.t_mappers(id_mapper) ON DELETE CASCADE;


COMMIT;
