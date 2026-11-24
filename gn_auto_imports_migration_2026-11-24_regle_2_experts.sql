-- =============================================================================
-- gn_auto_imports : mappeur 13 inat_bourdons_pdl, règle « au moins 2 experts d'accord »
-- 2026-11-24. Sauvegarde préalable : backup_gn_auto_imports_avant_regle_2_experts_2026-11-24.sql
--
-- * f_inat_expert_ident retient le taxon MAJORITAIRE parmi les identifications courantes
--   des experts (à égalité : le plus récemment proposé), au lieu du plus récent.
--   Nouvelles clés : n_experts, n_accord, autres_taxons.
-- * row_filter : n_accord >= 2 (un 3e expert en désaccord n'exclut pas l'observation).
-- * comment_description : description iNat + mention si le taxon final iNaturalist diffère
--   du taxon des experts, et mention du désaccord d'un expert.
-- =============================================================================
\set ON_ERROR_STOP on
BEGIN;

CREATE OR REPLACE FUNCTION gn_auto_imports.f_inat_expert_ident(p_identifications jsonb, p_user_ids text[])
 RETURNS jsonb
 LANGUAGE sql
AS $function$
    -- Détermination retenue pour une observation iNaturalist, à partir des identifications
    -- COURANTES des utilisateurs experts p_user_ids (le taxon de la communauté est ignoré) :
    -- le taxon proposé par le plus grand nombre d'experts ; à égalité, le plus récemment proposé.
    -- NULL si aucun expert n'a d'identification courante.
    WITH ident AS (
        SELECT x, (x ->> 'created_at')::timestamptz AS d,
               x -> 'user' ->> 'id' AS uid, x -> 'taxon' ->> 'id' AS tid
        FROM jsonb_array_elements(CASE WHEN jsonb_typeof(p_identifications) = 'array'
                                       THEN p_identifications ELSE '[]'::jsonb END) x
        WHERE x -> 'user' ->> 'id' = ANY (p_user_ids)
          AND COALESCE((x ->> 'current')::boolean, false)
    ), votes AS (
        SELECT tid, count(DISTINCT uid) AS n, max(d) AS last_d
        FROM ident GROUP BY tid
    ), top AS (
        SELECT tid, n FROM votes ORDER BY n DESC, last_d DESC LIMIT 1
    ), best AS (
        SELECT i.x, i.d, top.n,
               i.x -> 'taxon' ->> 'name' AS name,
               i.x -> 'taxon' ->> 'rank' AS rank,
               COALESCE((SELECT a ->> 'name' FROM jsonb_array_elements(i.x -> 'taxon' -> 'ancestors') a
                         WHERE a ->> 'rank' = 'genus' LIMIT 1),
                        CASE WHEN i.x -> 'taxon' ->> 'rank' = 'genus' THEN i.x -> 'taxon' ->> 'name'
                             ELSE split_part(i.x -> 'taxon' ->> 'name', ' ', 1) END) AS genus
        FROM ident i JOIN top ON top.tid = i.tid
        ORDER BY i.d DESC LIMIT 1
    ), names AS (
        -- nom d'un expert : t_inat_users, sinon nom iNaturalist, sinon login
        SELECT i.tid, i.x -> 'taxon' ->> 'name' AS taxon_name,
               COALESCE(u.display_name, NULLIF(i.x -> 'user' ->> 'name', ''), i.x -> 'user' ->> 'login') AS who
        FROM ident i
        LEFT JOIN gn_auto_imports.t_inat_users u ON u.user_id::text = i.uid
    )
    SELECT jsonb_build_object(
        'taxon_id', (b.x -> 'taxon' ->> 'id')::integer,
        'name',     b.name,
        'rank',     b.rank,
        'nom_cite', CASE b.rank
                        WHEN 'subgenus' THEN b.genus || ' (' || b.name || ')'
                        WHEN 'complex'  THEN b.name || ' (complexe)'
                        ELSE b.name END,
        'cd_nom',   gn_auto_imports.f_inat_taxref(b.name, b.rank, b.genus),
        'date',     b.d,
        -- experts dont l'identification courante porte sur le taxon retenu
        'determiner', (SELECT string_agg(DISTINCT n.who, ', ') FROM names n
                       WHERE n.tid = b.x -> 'taxon' ->> 'id'),
        'n_experts', (SELECT count(DISTINCT uid) FROM ident),
        'n_accord',  b.n,
        -- autres taxons proposés par des experts, ex. « Bombus lucorum (Gilles Mahé) »
        'autres_taxons', (SELECT string_agg(n.taxon_name || ' (' || n.who || ')', ', ' ORDER BY n.taxon_name, n.who)
                          FROM names n WHERE n.tid IS DISTINCT FROM b.x -> 'taxon' ->> 'id'))
    FROM best b;
$function$;

UPDATE gn_auto_imports.t_mappers
SET row_filter = $$(gn_auto_imports.f_inat_expert_ident(main.identifications::jsonb, '{8890201,9360526,7441090}') ->> 'rank') IN ('species', 'subspecies')
AND (gn_auto_imports.f_inat_expert_ident(main.identifications::jsonb, '{8890201,9360526,7441090}') ->> 'n_accord')::integer >= 2
AND main.obscured = 'false'
AND COALESCE(main.public_positional_accuracy::numeric, 0) < 500$$
WHERE id_mapper = 13;

UPDATE gn_auto_imports.t_mapper_fields
SET expression = $$NULLIF(concat_ws(E'\n',
  NULLIF(main.description, ''),
  CASE WHEN (main.taxon::jsonb ->> 'id') IS DISTINCT FROM (gn_auto_imports.f_inat_expert_ident(main.identifications::jsonb, '{8890201,9360526,7441090}') ->> 'taxon_id')
       THEN 'Un autre nom a été donné sous iNaturalist : ' || COALESCE(main.taxon::jsonb ->> 'name', '(aucun)') END,
  'Désaccord d''expert : ' || (gn_auto_imports.f_inat_expert_ident(main.identifications::jsonb, '{8890201,9360526,7441090}') ->> 'autres_taxons')
), '')$$
WHERE id_mapper = 13 AND target_column = 'comment_description';

COMMIT;
