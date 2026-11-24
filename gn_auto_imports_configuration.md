# `gn_auto_imports` : configuration

Voir aussi : [README](gn_auto_imports_README.md) · [Référence des fonctions](gn_auto_imports_fonctions.md)

La configuration tient dans trois tables : `t_mappers`, `t_mapper_fields` et `t_mapper_dependencies`.

---

## 1. `t_mappers` : un export API

### Source et téléchargement

| Colonne | Rôle |
|---|---|
| `id_mapper` | identifiant |
| `alias` | nom court (`^[a-z][a-z0-9_]+$`), unique ; donne le nom de la vue `v_<alias>_ready` |
| `active` | un mappeur inactif n'est pas lancé par `p_run_all`, et bloque les chaînes qui en dépendent |
| `url_api` | **URL complète de l'export**, ex. `https://geonature.bretagne-vivante.org/api/exports/api/31` |
| `token` | jeton de l'export, envoyé en paramètre `token` |
| `table_name` | table de staging (`gn_auto_imports.export_…`), créée automatiquement |
| `order_by_column` | clé de la ligne source : tri (`orderby`), index unique du staging, clé de découpage du push |
| `max_rows_limit` | taille de page (`limit`), 1000 par défaut |
| `starter_index_for_offset` | première page (`offset`), 0 par défaut. L'offset GeoNature est un **numéro de page** |
| `date_filter_query_param` | paramètre API du filtre de date (ex. `filter_d_up_meta_update_date`). NULL = rechargement complet à chaque run |
| `date_filter_source_field` | champ de date de mise à jour dans le staging (ex. `meta_update_date`). Il alimente `_source_update_date` |
| `id_filter_query_param` | paramètre API de filtre sur l'id (ex. `filter_d_up_id_synthese` pour GeoNature, `id_above` pour iNaturalist). Il sert à reprendre un chargement initial interrompu et, en pagination keyset, à passer d'une page à la suivante |
| `api_params` | paramètres fixes envoyés à chaque appel (jsonb), ex. `{"project_id": "276813", "order_by": "id", "order": "asc"}` |
| `pagination_mode` | `offset` (défaut, GeoNature) : numéro de page dans `page_param`. `keyset` : chaque page suivante est demandée avec `id_filter_query_param` = plus grand id reçu. L'API doit trier par id croissant, et `id_filter_query_param` est obligatoire |
| `page_size_param` | nom du paramètre de taille de page : `limit` (GeoNature, défaut), `per_page` (iNaturalist) |
| `page_param` | nom du paramètre de numéro de page en mode offset : `offset` (défaut) |
| `order_param` | nom du paramètre de tri, auquel on passe `order_by_column` : `orderby` (défaut). NULL = non envoyé, le tri est alors fixé dans `api_params` |
| `date_filter_format` | format de la date du filtre incrémental : `text` (défaut, `2026-11-19 09:00:00`, GeoNature) ou `iso` (`2026-11-19T09:00:00+01:00`, iNaturalist, qui ignore une date sans fuseau) |
| `request_delay_ms` | pause entre deux requêtes, en ms (0 par défaut ; 1000 pour iNaturalist) |
| `download_enabled` | `true` par défaut. `false` = pas de téléchargement : le mappeur relit le staging d'un autre mappeur (même `table_name`), dont il doit dépendre dans `t_mapper_dependencies` pour qu'il soit téléchargé avant lui. Ex. `inat_bourdons_pdl_medias` (photos) sur le staging de `inat_bourdons_pdl`. `url_api` reste obligatoire mais n'est pas utilisé |

Une date de mise à jour (`date_filter_source_field`) avec fuseau horaire est ramenée à l'heure locale
du serveur ; une date sans fuseau est prise telle quelle.

### Cible du push (terminaux)

| Colonne | Rôle |
|---|---|
| `is_terminal` | `true` = poussé vers `target_table` ; `false` = seulement téléchargé (dépendance) |
| `target_table` | table cible `schema.table` |
| `target_key_columns` | clé de correspondance cible ↔ source (composite possible), ex. `{unique_id_sinp}` |
| `target_scope_column` | colonne de périmètre, ex. `id_dataset`. Les UPDATE et DELETE sont limités au périmètre, et la valeur est ajoutée aux INSERT. NULL = pas de périmètre |
| `target_scope_value` / `target_dataset_id` | valeur du périmètre (`target_scope_value` en priorité) |
| `delete_flag_column` | colonne de la vue qui signale une suppression par la valeur `'D'` (ex. `last_action`). NULL = pas de suppression |
| `explode_column` | colonne JSON tableau à éclater : une ligne par élément, accessible par l'alias `item` |
| `target_parent_column` | (avec `explode_column`) colonne cible qui porte l'id du parent. Si elle est renseignée, les lignes cibles d'un parent qui ne sont plus dans son tableau sont **supprimées** |
| `row_filter` | condition SQL ajoutée en `WHERE` de la vue (alias `main`, `item` et alias des dépendances) |

### État et points de reprise (gérés par le code, ne pas éditer sauf pour une réinitialisation)

| Colonne | Rôle |
|---|---|
| `last_synchronization_date` | début du dernier téléchargement réussi : base du filtre incrémental |
| `last_import_date` | fin du dernier téléchargement réussi (information) |
| `last_imported_id` | plus grand id numérique téléchargé : reprise du chargement initial |
| `last_synthese_push_date` | watermark du push : seules les lignes avec `_source_update_date >=` sont candidates |
| `push_cursor` / `push_wm_max` | push par lots en cours : dernière clé validée (`''` = démarré, aucun lot) et borne haute figée |

Contraintes : `terminal_needs_scope_value`, `parent_needs_explode`, `target_key_columns_not_empty`,
`alias_typo`, `table_name_required` (NOT VALID). `target_dataset_id` est une clé étrangère vers
`gn_meta.t_datasets`.

---

## 2. `t_mapper_fields` : le mapping colonne par colonne

Une ligne par colonne cible (unique sur `id_mapper, target_column`). Seules les colonnes mappées
sont écrites : les autres colonnes de la cible gardent leur valeur par défaut à l'INSERT et ne sont
pas touchées à l'UPDATE.

| Colonne | Rôle |
|---|---|
| `target_column` | colonne de la table cible |
| `mapping_type` | `direct`, `constant`, `expression`, `geom_point`, `geom_geojson` ou `excluded` |
| `source_alias` | d'où vient la valeur : `main` (staging du mappeur, par défaut), `item` (élément éclaté) ou l'alias d'une dépendance |
| `source_column` | colonne source (`direct`, `geom_geojson`). Avec `item`, un chemin JSON pointé est possible : `validator.name` |
| `constant_value` | valeur (`constant`) |
| `expression` | expression SQL libre (`expression`), qui peut utiliser `main.`, `item.value`, `meta.`, … |
| `source_lon_column` / `source_lat_column` | pour `geom_point` |
| `source_srid` | SRID source des géométries (4326 par défaut) |
| `is_required`, `is_auto_generated` | informatifs (`is_auto_generated` = créé par `generate_mapper_fields`) |

Types de mapping :

| Type | SQL généré dans la vue |
|---|---|
| `direct` | `(main.col)::<type cible>` ; avec `item` : `(item.value #>> '{chemin}')::<type cible>` |
| `constant` | `('valeur')::<type cible>` |
| `expression` | `(<expression>)::<type cible>` |
| `geom_point` | `ST_Transform(ST_SetSRID(ST_MakePoint(lon, lat), srid), Find_SRID(cible))` |
| `geom_geojson` | `ST_Transform(ST_SetSRID(ST_GeomFromGeoJSON(col), srid), Find_SRID(cible))` |
| `excluded` | colonne ignorée (pour documenter un choix de ne pas la remplir) |

Le cast vers le type exact de la colonne cible est automatique (sauf pour les géométries). Comme
le staging est tout en `text`, une expression doit souvent caster elle-même ses entrées :
`abs(main.cd_nom::integer)`.

Exemples tirés de la configuration actuelle :

```sql
-- nomenclature : code BV → id local, valeur par défaut sinon
COALESCE(ref_nomenclatures.get_id_nomenclature('SEXE', main.id_nomenclature_sex),
         ref_nomenclatures.get_default_nomenclature_value('SEXE'))

-- enrichissement à partir d'une dépendance
COALESCE(main.additional_data, '{}')::jsonb || jsonb_build_object('dataset_json', meta.dataset_json::jsonb)

-- champ d'un élément éclaté (mappeur 12)
ref_nomenclatures.get_id_nomenclature('STATUT_VALID', item.value->>'cd_nomenclature')
```

Le mapping de la colonne de périmètre (ex. `id_dataset` en `constant`) peut exister mais n'est pas
utilisé : la valeur insérée est toujours `target_scope_value` / `target_dataset_id`.

### Vues d'aide

- `v_mapping_report` : pour chaque colonne du staging, la colonne cible mappée, ou `non mappé`.
- `v_missing_required_fields` : les colonnes NOT NULL sans défaut de la cible qui n'ont pas de mapping.

---

## 3. `t_mapper_dependencies` : les jointures entre stagings

| Colonne | Rôle |
|---|---|
| `id_mapper` | le mappeur qui joint |
| `id_mapper_dependency` | le mappeur joint (son staging) |
| `dependency_alias` | alias SQL dans la vue (`^[a-z][a-z0-9_]*$`, ni `main` ni `item`) |
| `main_join_column` / `dependency_join_column` | condition `alias.dependency_join_column = main.main_join_column` |
| `join_type` | `left` ou `inner` (un `inner` sert de filtre) |
| `contributes_update_date` | la date de mise à jour de la dépendance entre-t-elle dans `_source_update_date` ? (`GREATEST` des dates). Mettre `false` pour une dépendance qui sert seulement de filtre |
| `execution_order` | ordre entre dépendances de même niveau |

L'ordre d'exécution est calculé par `f_get_sync_plan` : les dépendances les plus profondes d'abord,
et un mappeur partagé passe avant tous ses dépendants. Un cycle lève une erreur.

Une dépendance peut être un terminal : il est alors poussé **avant** le terminal qui en dépend
(ex. les observations avant les validations).

Garde-fou : si une jointure 1:N produit plusieurs lignes pour une même clé cible, le push échoue
(`clé(s) en double dans la vue`). La jointure doit donc rester 1:1 sur la clé.

---

## 4. Exemple : une API qui n'est pas GeoNature (iNaturalist)

Les paramètres GeoNature (`limit`, `offset`, `orderby`) sont ignorés par iNaturalist, et sa pagination
par `page` est plafonnée à 10 000 résultats. Le mappeur `inat_bourdons_pdl` utilise donc :

```sql
url_api                 = 'https://api.inaturalist.org/v1/observations'
api_params              = '{"project_id": "276813", "ident_user_id": "8890201,9360526,7441090",
                            "geo": "true", "order_by": "id", "order": "asc"}'
order_by_column         = 'id'
pagination_mode         = 'keyset'        -- page suivante : id_above = plus grand id reçu
id_filter_query_param   = 'id_above'
page_size_param         = 'per_page'      -- max 200 chez iNaturalist
max_rows_limit          = 200
page_param, order_param = NULL
date_filter_query_param = 'updated_since'
date_filter_format      = 'iso'
date_filter_source_field= 'updated_at'
request_delay_ms        = 1000
```

La réponse (`{"total_results", "page", "per_page", "results": [...]}`) est lue par `f_extract_rows`
(clé `results`). Les champs objets (`taxon`, `user`, `geojson`, `identifications`…) sont stockés en
texte JSON dans le staging, et lus dans les expressions : `main."user"::jsonb ->> 'login'`
(`user` est un mot réservé, il faut les guillemets), `ST_GeomFromGeoJSON(main.geojson)`, …

---

### Réutiliser un téléchargement : les photos iNaturalist

Pour alimenter une seconde table à partir des mêmes données sources, sans rappeler l'API :

```sql
-- t_mappers : même table_name que inat_bourdons_pdl, pas de téléchargement, une ligne par photo
download_enabled     = false
table_name           = 'gn_auto_imports.export_inat_bourdons_pdl'
explode_column       = 'photos'
target_table         = 'gn_commons.t_medias'
target_key_columns   = '{unique_id_media}'     -- UUID v5 calculé depuis l'id de la photo
target_parent_column = 'uuid_attached_row'     -- nettoyage des photos retirées
target_scope_column  = NULL, delete_flag_column = NULL
-- t_mapper_dependencies : dépendance d'ordre vers inat_bourdons_pdl (alias obs, inner, contributes_update_date = false)
```

## 5. Ajouter un nouveau mappeur (procédure)

1. **Déclarer le mappeur**, inactif pour commencer :

   ```sql
   INSERT INTO gn_auto_imports.t_mappers
     (alias, url_api, token, table_name, order_by_column,
      date_filter_query_param, date_filter_source_field, id_filter_query_param,
      is_terminal, target_table, target_key_columns, target_scope_column, target_dataset_id,
      delete_flag_column, active)
   VALUES
     ('synchro_xxx', 'https://…/api/exports/api/<id_export>', '<token>',
      'gn_auto_imports.export_synchro_xxx', 'id_synthese',
      'filter_d_up_meta_update_date', 'meta_update_date', 'filter_d_up_id_synthese',
      true, 'gn_synthese.synthese', '{unique_id_sinp}', 'id_dataset', <id_jdd_local>,
      'last_action', true);
   ```

   Pour une première descente qui ne touche pas la cible, laisser `is_terminal = false`.

2. **Télécharger une première fois** pour créer le staging et ses colonnes :

   ```sql
   CALL gn_auto_imports.p_download_mapper(<id>, true);
   ```

3. **Générer un mapping de base** (colonnes de même nom dans le staging et la cible) :

   ```sql
   CALL gn_auto_imports.generate_mapper_fields(<id>);
   ```

4. **Compléter le mapping** dans `t_mapper_fields` (nomenclatures, géométries, constantes comme
   `id_source`, …), puis vérifier :

   ```sql
   SELECT * FROM gn_auto_imports.v_mapping_report WHERE id_mapper = <id>;
   SELECT * FROM gn_auto_imports.v_missing_required_fields WHERE id_mapper = <id>;
   SELECT gn_auto_imports.f_build_ready_view(<id>, false);   -- relire le SQL généré
   ```

5. **Déclarer les dépendances** éventuelles dans `t_mapper_dependencies`.

6. **Passer le mappeur en terminal** si besoin, puis faire le chargement initial :

   ```sql
   CALL gn_auto_imports.p_run_terminal(<id>, true, '{}', 10000);
   ```

   Les runs suivants passent par `p_run_all()`.
