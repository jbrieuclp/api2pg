-- =============================================================================
-- gn_auto_imports : module complémentaire iNaturalist
-- Créé le 2026-11-24 (extrait de gn_auto_imports_deploy_01_structure.sql)
--
-- Objets propres à iNaturalist, utilisés par les expressions et le row_filter des
-- mappeurs iNat (t_mapper_fields, t_mappers) :
--   * t_inat_taxref_cache  : cache taxon iNat -> cd_nom TaxRef (à vider après mise à jour de TaxRef)
--   * t_inat_users         : noms d'affichage des experts (champ determiner)
--   * f_inat_taxref        : correspondance taxon iNat -> cd_nom
--   * f_inat_expert_ident  : taxon retenu d'après les identifications des experts
--
-- Prérequis : gn_auto_imports_deploy_01_structure.sql (cœur) déjà installé.
-- Ce script peut être relancé : tables créées si absentes, fonctions remplacées
-- (sert aussi à mettre à jour les fonctions du module sur une base déjà équipée).
--
-- Usage :
--   psql -h <hôte> -p <port> -U <user> -d <base> -f gn_auto_imports_module_inaturalist.sql
--   puis la configuration des mappeurs : gn_auto_imports_deploy_03_config_inaturalist.sql
-- =============================================================================

\set ON_ERROR_STOP on

BEGIN;

DO $$
BEGIN
    IF to_regclass('gn_auto_imports.t_mappers') IS NULL THEN
        RAISE EXCEPTION 'Cœur gn_auto_imports absent : lancer d''abord gn_auto_imports_deploy_01_structure.sql';
    END IF;
END $$;

--
-- Name: t_inat_taxref_cache; Type: TABLE; Schema: gn_auto_imports; Owner: -
--

CREATE TABLE IF NOT EXISTS gn_auto_imports.t_inat_taxref_cache (
    name text NOT NULL,
    rank text NOT NULL,
    genus text DEFAULT ''::text NOT NULL,
    cd_nom integer,
    created_at timestamp without time zone DEFAULT now() NOT NULL,
    CONSTRAINT t_inat_taxref_cache_pkey PRIMARY KEY (name, rank, genus)
);


--
-- Name: TABLE t_inat_taxref_cache; Type: COMMENT; Schema: gn_auto_imports; Owner: -
--

COMMENT ON TABLE gn_auto_imports.t_inat_taxref_cache IS 'Cache de correspondance taxon iNaturalist -> TaxRef (f_inat_taxref). À vider (TRUNCATE) après une mise à jour de TaxRef ou pour forcer une nouvelle recherche.';


--
-- Name: t_inat_users; Type: TABLE; Schema: gn_auto_imports; Owner: -
--

CREATE TABLE IF NOT EXISTS gn_auto_imports.t_inat_users (
    user_id integer NOT NULL,
    login text,
    display_name text NOT NULL,
    CONSTRAINT t_inat_users_pkey PRIMARY KEY (user_id)
);


--
-- Name: TABLE t_inat_users; Type: COMMENT; Schema: gn_auto_imports; Owner: -
--

COMMENT ON TABLE gn_auto_imports.t_inat_users IS 'Noms d''affichage d''utilisateurs iNaturalist (prioritaires sur le nom iNat) pour le champ determiner (f_inat_expert_ident)';


--
-- Name: f_inat_expert_ident(jsonb, text[]); Type: FUNCTION; Schema: gn_auto_imports; Owner: -
--

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


--
-- Name: f_inat_taxref(text, text, text); Type: FUNCTION; Schema: gn_auto_imports; Owner: -
--

CREATE OR REPLACE FUNCTION gn_auto_imports.f_inat_taxref(p_name text, p_rank text, p_genus text DEFAULT NULL::text) RETURNS integer
    LANGUAGE plpgsql
    AS $$
-- Correspondance d'un taxon iNaturalist avec TaxRef (cd_nom), via le cache t_inat_taxref_cache
-- (taxonomie.taxref n'a pas d'index sur lb_nom : une recherche = un parcours complet).
-- Rangs sans équivalent dans TaxRef (sous-genre, complexe, section...) : rattachement au genre.
DECLARE
    v_cd_nom integer;
BEGIN
    IF p_name IS NULL THEN
        RETURN NULL;
    END IF;

    SELECT c.cd_nom INTO v_cd_nom
    FROM gn_auto_imports.t_inat_taxref_cache c
    WHERE c.name = p_name AND c.rank = COALESCE(p_rank, '') AND c.genus = COALESCE(p_genus, '');
    IF FOUND THEN
        RETURN v_cd_nom;
    END IF;

    SELECT COALESCE(
        (SELECT t.cd_nom FROM taxonomie.taxref t
         WHERE t.lb_nom = p_name
           AND t.id_rang = CASE p_rank WHEN 'species' THEN 'ES' WHEN 'subspecies' THEN 'SSES'
                                       WHEN 'variety' THEN 'VAR' WHEN 'form' THEN 'FO'
                                       WHEN 'genus' THEN 'GN' END
         ORDER BY (t.regne = 'Animalia') DESC, (t.cd_nom = t.cd_ref) DESC, t.cd_nom
         LIMIT 1),
        (SELECT t.cd_nom FROM taxonomie.taxref t
         WHERE t.lb_nom = p_genus AND t.id_rang = 'GN'
         ORDER BY (t.regne = 'Animalia') DESC, (t.cd_nom = t.cd_ref) DESC, t.cd_nom
         LIMIT 1))
    INTO v_cd_nom;

    -- Mise en cache ; un rôle en lecture seule obtient le résultat sans écrire
    BEGIN
        INSERT INTO gn_auto_imports.t_inat_taxref_cache (name, rank, genus, cd_nom)
        VALUES (p_name, COALESCE(p_rank, ''), COALESCE(p_genus, ''), v_cd_nom)
        ON CONFLICT DO NOTHING;
    EXCEPTION WHEN insufficient_privilege OR read_only_sql_transaction THEN
        NULL;
    END;

    RETURN v_cd_nom;
END;
$$;

COMMIT;
