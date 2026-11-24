-- =============================================================================
-- gn_auto_imports : configuration du mappeur iNaturalist « Bourdons des Pays de la Loire »
-- Généré le 2026-11-19 depuis la base d'origine
--
-- À lancer APRÈS gn_auto_imports_deploy_01_structure.sql (cœur) PUIS
-- gn_auto_imports_module_inaturalist.sql (fonctions et tables iNat). Indépendant du script 02.
--
-- Source : collection iNaturalist 276813, observations identifiées par les experts
--   7441090 (axelpajot), 8890201 (gilles-mahe), 9360526 (baptiste-hubert).
-- Taxon retenu : taxon majoritaire parmi les identifications courantes de ces experts
--   (f_inat_expert_ident), et non celui de la communauté.
-- Filtre (row_filter) : détermination à l'espèce ou à la sous-espèce, au moins 2 experts
--   d'accord sur le taxon (taxon majoritaire retenu), observation non floutée, précision < 500 m.
--
-- Dépendances côté base cible (à vérifier / adapter avant de lancer) :
--   * gn_meta.t_datasets.id_dataset = 3159   (JDD cible, clé étrangère)
--   * la source « API iNaturalist » est créée dans gn_synthese.t_sources si absente
-- Après déploiement :
--   CALL gn_auto_imports.p_run_terminal((id du mappeur inat_bourdons_pdl_medias), true, '{}', 10000);
--   (télécharge et pousse les observations, puis pousse leurs photos dans gn_commons.t_medias)
-- =============================================================================

\set ON_ERROR_STOP on

BEGIN;

INSERT INTO gn_synthese.t_sources (name_source, desc_source, entity_source_pk_field)
SELECT 'API iNaturalist', 'Synchronisation automatique via gn_auto_imports (mapper inat_bourdons_pdl)', 'id'
WHERE NOT EXISTS (SELECT 1 FROM gn_synthese.t_sources WHERE name_source = 'API iNaturalist');

INSERT INTO gn_auto_imports.t_mappers
  (alias, url_api, table_name, order_by_column, is_terminal, active,
   api_params, pagination_mode, page_size_param, page_param, order_param, max_rows_limit,
   date_filter_query_param, date_filter_format, date_filter_source_field, id_filter_query_param,
   request_delay_ms,
   target_table, target_key_columns, target_scope_column, target_dataset_id, delete_flag_column, row_filter)
VALUES
  ('inat_bourdons_pdl', 'https://api.inaturalist.org/v1/observations', 'gn_auto_imports.export_inat_bourdons_pdl', 'id', true, true,
   '{"project_id": "276813", "ident_user_id": "8890201,9360526,7441090", "geo": "true", "order_by": "id", "order": "asc"}',
   'keyset', 'per_page', NULL, NULL, 200,
   'updated_since', 'iso', 'updated_at', 'id_above',
   1000,
   'gn_synthese.synthese', '{unique_id_sinp}', 'id_dataset', 3159, NULL,
   -- espèce ou sous-espèce, au moins 2 experts d'accord, non floutée, précision publique < 500 m
   '(gn_auto_imports.f_inat_expert_ident(main.identifications::jsonb, ''{8890201,9360526,7441090}'') ->> ''rank'') IN (''species'', ''subspecies'')
AND (gn_auto_imports.f_inat_expert_ident(main.identifications::jsonb, ''{8890201,9360526,7441090}'') ->> ''n_accord'')::integer >= 2
AND main.obscured = ''false''
AND COALESCE(main.public_positional_accuracy::numeric, 0) < 500');

INSERT INTO gn_auto_imports.t_mapper_fields (id_mapper, target_column, mapping_type, source_column, constant_value, expression)
SELECT (SELECT id_mapper FROM gn_auto_imports.t_mappers WHERE alias = 'inat_bourdons_pdl'), c, t, s, k, e FROM (VALUES
 ('unique_id_sinp',          'direct',   'uuid', NULL, NULL),
 ('entity_source_pk_value',  'direct',   'id',   NULL, NULL),
 ('id_source',               'constant', NULL, (SELECT id_source::text FROM gn_synthese.t_sources WHERE name_source = 'API iNaturalist'), NULL),
 ('id_dataset',              'constant', NULL, '3159', NULL),
 -- détermination des experts (identification courante la plus récente), pas celle de la communauté
 ('nom_cite',   'expression', NULL, NULL, 'gn_auto_imports.f_inat_expert_ident(main.identifications::jsonb, ''{8890201,9360526,7441090}'') ->> ''nom_cite'''),
 ('cd_nom',     'expression', NULL, NULL, 'gn_auto_imports.f_inat_expert_ident(main.identifications::jsonb, ''{8890201,9360526,7441090}'') ->> ''cd_nom'''),
 ('determiner', 'expression', NULL, NULL, 'gn_auto_imports.f_inat_expert_ident(main.identifications::jsonb, ''{8890201,9360526,7441090}'') ->> ''determiner'''),
 ('date_min',   'expression', NULL, NULL, 'COALESCE(main.time_observed_at::timestamptz::timestamp, main.observed_on::timestamp)'),
 ('date_max',   'expression', NULL, NULL, 'COALESCE(main.time_observed_at::timestamptz::timestamp, main.observed_on::timestamp)'),
 ('observers',  'expression', NULL, NULL, 'COALESCE(NULLIF(main."user"::jsonb ->> ''name'', ''''), main."user"::jsonb ->> ''login'')'),
 ('the_geom_4326',       'expression', NULL, NULL, 'ST_SetSRID(ST_GeomFromGeoJSON(main.geojson), 4326)'),
 ('the_geom_local',      'expression', NULL, NULL, 'ST_Transform(ST_SetSRID(ST_GeomFromGeoJSON(main.geojson), 4326), 2154)'),
 ('the_geom_point',      'expression', NULL, NULL, 'ST_Centroid(ST_SetSRID(ST_GeomFromGeoJSON(main.geojson), 4326))'),
 ('the_geom_point_2154', 'expression', NULL, NULL, 'ST_Transform(ST_Centroid(ST_SetSRID(ST_GeomFromGeoJSON(main.geojson), 4326)), 2154)'),
 ('precision',  'expression', NULL, NULL, 'round(NULLIF(main.public_positional_accuracy, '''')::numeric)'),
 ('id_nomenclature_blurring',    'expression', NULL, NULL, 'ref_nomenclatures.get_id_nomenclature(''DEE_FLOU'', CASE WHEN main.obscured = ''true'' THEN ''OUI'' ELSE ''NON'' END)'),
 ('id_nomenclature_exist_proof', 'expression', NULL, NULL, 'ref_nomenclatures.get_id_nomenclature(''PREUVE_EXIST'', ''1'')'),
 ('digital_proof',       'expression', NULL, NULL, 'replace(main.uri, ''http://'', ''https://'')'),
 ('place_name',          'direct',     'place_guess', NULL, NULL),
 -- description iNat + « Un autre nom a été donné sous iNaturalist » + désaccord d'expert
 ('comment_description', 'expression', NULL, NULL, E'NULLIF(concat_ws(E''\\n'',
  NULLIF(main.description, ''''),
  CASE WHEN (main.taxon::jsonb ->> ''id'') IS DISTINCT FROM (gn_auto_imports.f_inat_expert_ident(main.identifications::jsonb, ''{8890201,9360526,7441090}'') ->> ''taxon_id'')
       THEN ''Un autre nom a été donné sous iNaturalist : '' || COALESCE(main.taxon::jsonb ->> ''name'', ''(aucun)'') END,
  ''Désaccord d''''expert : '' || (gn_auto_imports.f_inat_expert_ident(main.identifications::jsonb, ''{8890201,9360526,7441090}'') ->> ''autres_taxons'')
), '''')'),
 ('additional_data',     'expression', NULL, NULL,
  'jsonb_strip_nulls(jsonb_build_object(''source_donnees'', ''iNaturalist'', ''inat_id'', main.id::bigint, '
  '''quality_grade'', main.quality_grade, ''license_code'', NULLIF(main.license_code, ''''), '
  '''taxon_communaute'', main.taxon::jsonb ->> ''name'', ''rang_communaute'', main.taxon::jsonb ->> ''rank'', '
  '''date_determination'', gn_auto_imports.f_inat_expert_ident(main.identifications::jsonb, ''{8890201,9360526,7441090}'') ->> ''date''))')
) v(c, t, s, k, e);

-- Noms d'affichage des experts (champ determiner), prioritaires sur le nom iNaturalist
INSERT INTO gn_auto_imports.t_inat_users (user_id, login, display_name) VALUES
  (8890201, 'gilles-mahe',     'Gilles Mahé'),
  (9360526, 'baptiste-hubert', 'Baptiste Hubert')
ON CONFLICT (user_id) DO UPDATE SET login = EXCLUDED.login, display_name = EXCLUDED.display_name;

-- -----------------------------------------------------------------------------
-- Mappeur inat_bourdons_pdl_medias : photos des observations -> gn_commons.t_medias
-- Pas de téléchargement propre (download_enabled = false) : il relit le staging de
-- inat_bourdons_pdl et éclate la colonne photos (une ligne par photo).
-- -----------------------------------------------------------------------------
INSERT INTO gn_auto_imports.t_mappers
  (alias, url_api, table_name, order_by_column, is_terminal, active, download_enabled,
   date_filter_source_field, explode_column,
   target_table, target_key_columns, target_parent_column, target_scope_column, delete_flag_column, row_filter)
VALUES
  ('inat_bourdons_pdl_medias', 'https://api.inaturalist.org/v1/observations',
   'gn_auto_imports.export_inat_bourdons_pdl', 'id', true, true, false,
   'updated_at', 'photos',
   'gn_commons.t_medias', '{unique_id_media}', 'uuid_attached_row', NULL, NULL,
   'EXISTS (SELECT 1 FROM gn_synthese.synthese s WHERE s.unique_id_sinp = main.uuid::uuid AND s.id_dataset = 3159)');

INSERT INTO gn_auto_imports.t_mapper_fields (id_mapper, target_column, mapping_type, source_alias, source_column, constant_value, expression)
SELECT (SELECT id_mapper FROM gn_auto_imports.t_mappers WHERE alias = 'inat_bourdons_pdl_medias'), c, t, 'main', s, k, e FROM (VALUES
 ('unique_id_media',            'expression', NULL, NULL, 'uuid_generate_v5(uuid_ns_url(), ''https://www.inaturalist.org/photos/'' || (item.value->>''id''))'),
 ('uuid_attached_row',          'direct',     'uuid', NULL, NULL),
 ('id_table_location',          'constant',   NULL, '1', NULL),
 ('id_nomenclature_media_type', 'expression', NULL, NULL, 'ref_nomenclatures.get_id_nomenclature(''TYPE_MEDIA'', ''2'')'),
 ('media_url',                  'expression', NULL, NULL, 'replace(item.value->>''url'', ''/square.'', ''/original.'')'),
 ('title_fr',                   'expression', NULL, NULL, '''Photo iNaturalist '' || (item.value->>''id'') || '' (observation '' || main.id || '')'''),
 ('author',                     'expression', NULL, NULL, 'left(regexp_replace(item.value->>''attribution'', ''^\(c\)\s*|,\s*(some|all|no) rights reserved.*$'', '''', ''g''), 100)'),
 ('description_fr',             'expression', NULL, NULL, 'concat_ws('' – '', item.value->>''attribution'', ''https://www.inaturalist.org/photos/'' || (item.value->>''id''))'),
 ('is_public',                  'constant',   NULL, 'true', NULL)
) v(c, t, s, k, e);

-- Dépendance d'ordre : les observations sont téléchargées et poussées avant les photos
INSERT INTO gn_auto_imports.t_mapper_dependencies
  (id_mapper, id_mapper_dependency, execution_order, dependency_alias, main_join_column, dependency_join_column, join_type, contributes_update_date)
SELECT d.id_mapper, o.id_mapper, 0, 'obs', 'id', 'id', 'inner', false
FROM gn_auto_imports.t_mappers d, gn_auto_imports.t_mappers o
WHERE d.alias = 'inat_bourdons_pdl_medias' AND o.alias = 'inat_bourdons_pdl';

COMMIT;
