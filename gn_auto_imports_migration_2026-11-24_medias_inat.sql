-- =============================================================================
-- gn_auto_imports : mappeur 14 inat_bourdons_pdl_medias (photos iNat -> gn_commons.t_medias)
-- 2026-11-24. Sauvegarde préalable : backup_gn_auto_imports_avant_medias_inat_2026-11-24.sql
-- =============================================================================
\set ON_ERROR_STOP on
BEGIN;

ALTER TABLE gn_auto_imports.t_mappers
  ADD COLUMN IF NOT EXISTS download_enabled boolean NOT NULL DEFAULT true;
COMMENT ON COLUMN gn_auto_imports.t_mappers.download_enabled IS
  'false = pas de téléchargement : le mappeur relit le staging (table_name) d''un autre mappeur, dont il doit dépendre';

CREATE OR REPLACE PROCEDURE gn_auto_imports.p_run_terminal(IN p_id_terminal integer, IN p_commit_per_page boolean DEFAULT false, INOUT p_done integer[] DEFAULT '{}'::integer[], IN p_push_batch_size integer DEFAULT NULL::integer, IN p_id_run bigint DEFAULT NULL::bigint)
 LANGUAGE plpgsql
AS $procedure$
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
$procedure$

;
CREATE OR REPLACE PROCEDURE gn_auto_imports.p_download_mapper(IN p_id_mapper integer, IN p_commit_per_page boolean DEFAULT false)
 LANGUAGE plpgsql
AS $procedure$
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
$procedure$

;

-- Mappeur 14 : relit le staging du 13, une ligne par photo
INSERT INTO gn_auto_imports.t_mappers
  (id_mapper, alias, url_api, table_name, order_by_column, is_terminal, active, download_enabled,
   date_filter_source_field, explode_column,
   target_table, target_key_columns, target_parent_column, target_scope_column, delete_flag_column, row_filter)
VALUES
  (14, 'inat_bourdons_pdl_medias', 'https://api.inaturalist.org/v1/observations',
   'gn_auto_imports.export_inat_bourdons_pdl', 'id', true, true, false,
   'updated_at', 'photos',
   'gn_commons.t_medias', '{unique_id_media}', 'uuid_attached_row', NULL, NULL,
   -- seulement les observations effectivement présentes dans la synthèse (JDD 3159)
   'EXISTS (SELECT 1 FROM gn_synthese.synthese s WHERE s.unique_id_sinp = main.uuid::uuid AND s.id_dataset = 3159)');

INSERT INTO gn_auto_imports.t_mapper_fields (id_mapper, target_column, mapping_type, source_alias, source_column, constant_value, expression)
VALUES
 -- UUID stable dérivé de l'id de la photo iNat (UUID v5, espace de noms URL)
 (14, 'unique_id_media',            'expression', 'main', NULL, NULL, 'uuid_generate_v5(uuid_ns_url(), ''https://www.inaturalist.org/photos/'' || (item.value->>''id''))'),
 (14, 'uuid_attached_row',          'direct',     'main', 'uuid', NULL, NULL),
 (14, 'id_table_location',          'constant',   'main', NULL, '1', NULL),
 (14, 'id_nomenclature_media_type', 'expression', 'main', NULL, NULL, 'ref_nomenclatures.get_id_nomenclature(''TYPE_MEDIA'', ''2'')'),
 (14, 'media_url',                  'expression', 'main', NULL, NULL, 'replace(item.value->>''url'', ''/square.'', ''/original.'')'),
 (14, 'title_fr',                   'expression', 'main', NULL, NULL, '''Photo iNaturalist '' || (item.value->>''id'') || '' (observation '' || main.id || '')'''),
 (14, 'author',                     'expression', 'main', NULL, NULL, 'left(regexp_replace(item.value->>''attribution'', ''^\(c\)\s*|,\s*(some|all|no) rights reserved.*$'', '''', ''g''), 100)'),
 (14, 'description_fr',             'expression', 'main', NULL, NULL, 'concat_ws('' – '', item.value->>''attribution'', ''https://www.inaturalist.org/photos/'' || (item.value->>''id''))'),
 (14, 'is_public',                  'constant',   'main', NULL, 'true', NULL);

-- 14 dépend de 13 : 13 est téléchargé et poussé avant 14 (dépendance d'ordre seulement)
INSERT INTO gn_auto_imports.t_mapper_dependencies
  (id_mapper, id_mapper_dependency, execution_order, dependency_alias, main_join_column, dependency_join_column, join_type, contributes_update_date)
VALUES (14, 13, 0, 'obs', 'id', 'id', 'inner', false);

SELECT setval(pg_get_serial_sequence('gn_auto_imports.t_mappers', 'id_mapper'),
              GREATEST((SELECT max(id_mapper) FROM gn_auto_imports.t_mappers), 1))
WHERE pg_get_serial_sequence('gn_auto_imports.t_mappers', 'id_mapper') IS NOT NULL;

COMMIT;
