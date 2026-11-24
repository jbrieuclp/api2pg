# `gn_auto_imports` : référence des fonctions et procédures

Voir aussi : [README](gn_auto_imports_README.md) · [Configuration](gn_auto_imports_configuration.md)

## Graphe d'appels

```
p_run_all(alias)
 └─ p_run_terminal(id, commit, done, batch, run)        verrous 7421, id_run
     ├─ f_get_sync_plan(id) ── f_walk_dependencies(id)
     ├─ p_download_mapper(id, commit)                   pour chaque mappeur de la chaîne
     │   ├─ f_staging_ref
     │   ├─ f_api_get ─► API (extension http)
     │   ├─ f_extract_rows
     │   └─ f_step_start / f_step_update
     └─ pour chaque terminal de la chaîne :
         ├─ f_push_to_target(id)                         push en une transaction
         └─ p_push_to_target(id, batch)                  push par lots avec COMMIT
             └─ f_push_to_target(id, de, à, wm, false)   un lot
                 └─ f_build_ready_view(id) ── f_walk_dependencies, f_staging_ref, f_source_ref

Module iNaturalist (gn_auto_imports_module_inaturalist.sql), appelées depuis le mapping iNat
(expressions de t_mapper_fields, row_filter) :
  f_inat_expert_ident ── f_inat_taxref ── cache t_inat_taxref_cache

Hors pipeline : generate_mapper_fields
```

---

## Orchestration

### `p_run_all(p_alias text DEFAULT NULL)` (procédure)

Lance `p_run_terminal` pour chaque mappeur `is_terminal AND active`, ou pour le seul alias donné,
par ordre d'`id_mapper`. Chaque chaîne reçoit son `id_run` (séquence `t_sync_run_seq`).

- Les mappeurs téléchargés sont partagés entre chaînes via `done` : un mappeur n'est jamais téléchargé deux fois dans le même run.
- En cas d'erreur sur une chaîne : les verrous 7421 de la chaîne sont libérés, une ligne `error` est
  ajoutée à `t_sync_log`, un `WARNING` est levé, puis la chaîne suivante est lancée.
- Appelle `p_run_terminal` avec `commit_per_page = false` et sans lots : l'ensemble est validé en fin de `CALL`.

### `p_run_terminal(p_id_terminal int, p_commit_per_page bool DEFAULT false, INOUT p_done int[] DEFAULT '{}', p_push_batch_size int DEFAULT NULL, p_id_run bigint DEFAULT NULL)` (procédure)

Exécute la chaîne complète d'un terminal :

1. vérifie que le mappeur existe, qu'il est terminal et actif ; calcule le plan (`f_get_sync_plan`,
   erreur en cas de cycle) ; vérifie que tous les mappeurs de la chaîne sont actifs ;
2. prend un verrou de session `pg_try_advisory_lock(7421, id)` sur **chaque terminal** de la chaîne.
   Si l'un d'eux est déjà pris par une autre session : `NOTICE` et sortie sans erreur.
   Un verrou déjà détenu par la session courante est réutilisé ;
3. pose `gn_auto_imports.id_run` dans la session (lu par `f_step_start`) ;
4. télécharge chaque mappeur du plan qui n'est pas dans `p_done` et dont `download_enabled` est vrai (`p_download_mapper`) ;
5. pousse chaque terminal de la chaîne, dépendances d'abord : `p_push_to_target` si
   `p_push_batch_size` est renseigné, `f_push_to_target` sinon. Un terminal dépendant déjà poussé
   plus tôt dans le run n'est pas repoussé ;
6. écrit une ligne `success` dans `t_sync_log` par terminal poussé
   (`rows_imported` = inserted + updated, `rows_skipped_other_dataset`, `rows_deleted` = deleted + orphans_deleted) ;
7. COMMIT après chaque terminal si `p_commit_per_page`, puis libère les verrous.

`p_commit_per_page = true` ou `p_push_batch_size` non NULL : appel obligatoire hors bloc de transaction.

### `f_get_sync_plan(p_id_terminal int)` → `TABLE(step, id_mapper, alias, table_name, is_terminal)`

Ordre d'exécution de la chaîne : la profondeur maximale d'abord (un mappeur partagé passe avant
tous ses dépendants), puis `execution_order`, puis `id_mapper`. Lève une erreur si le mappeur
n'existe pas ou en cas de cycle.

```sql
SELECT * FROM gn_auto_imports.f_get_sync_plan(12);
-- 1 | 7 synchro_bv_mtd | 2 | 5 synchro_bv | 3 | 12 synchro_bv_validations
```

### `f_walk_dependencies(p_id_terminal int)` → `TABLE(node, depth, ord, is_cycle)`

Parcours récursif de `t_mapper_dependencies` depuis le terminal. `is_cycle` marque un retour sur un
nœud déjà visité, et le parcours s'arrête sur ce nœud.

---

## Téléchargement

### `p_download_mapper(p_id_mapper int, p_commit_per_page bool DEFAULT false)` (procédure)

Télécharge un export dans son staging. Si `download_enabled = false`, il ne fait rien (`NOTICE`).

1. Crée le staging s'il est absent (`CREATE TABLE … (<order_by_column> text)`) et un index unique sur la clé.
2. Construit les paramètres : `api_params`, `token`, `<order_param> = order_by_column` (si
   `order_param` est renseigné), puis selon le mode :

   | Mode | Condition | Paramètre ajouté |
   |---|---|---|
   | `incremental` | `last_synchronization_date` renseignée et `date_filter_query_param` défini | `<date_filter_query_param> = last_synchronization_date - 5 min`, au format `date_filter_format` (`text` ou `iso` avec fuseau) |
   | `reprise_id` | sinon, si `id_filter_query_param` et `last_imported_id` sont renseignés | `<id_filter_query_param> = last_imported_id` |
   | `complet` | sinon | (aucun) |

3. Boucle sur les pages, avec `<page_size_param> = max_rows_limit`, jusqu'à une page plus courte que la taille demandée :
   - `pagination_mode = 'offset'` : `<page_param>` = numéro de page, à partir de `starter_index_for_offset` ;
   - `pagination_mode = 'keyset'` : pas de numéro de page ; après chaque page,
     `<id_filter_query_param>` = plus grand id reçu (erreur si la clé n'est pas numérique) ;
   - pause de `request_delay_ms` entre deux requêtes.

   Pour chaque page :
   - erreur si une ligne n'a pas de valeur de clé ;
   - ajout au staging des colonnes inconnues (en `text`) : le staging suit l'évolution de l'export ;
   - upsert (`INSERT … ON CONFLICT (clé) DO UPDATE`) des colonnes présentes dans la page ;
   - mise à jour de `last_imported_id` (plus grand id numérique) dans la même transaction ;
   - mise à jour de l'étape `download` (lignes, pages, temps API `api_s` et base `db_s`) ;
   - COMMIT si `p_commit_per_page`.
4. En fin de téléchargement : `last_synchronization_date` = heure de **début** du téléchargement,
   `last_import_date = now()`.

### `f_api_get(p_url text, p_params jsonb DEFAULT '{}')` → `jsonb`

GET HTTP (extension `http`). Les paramètres sont encodés en query string, ajoutée avec `&` si
l'URL en contient déjà une. User-Agent : `gn_auto_imports (GeoNature sync)`. Délais : 15 s de
connexion, 120 s au total. Un statut hors 2xx lève une exception, avec l'URL **sans** paramètres
pour ne pas exposer le token. Pas de nouvelle tentative automatique.

### `f_extract_rows(p_payload jsonb)` → `jsonb` (IMMUTABLE)

Extrait le tableau de lignes d'une réponse : tableau brut, clé `items`, `data` ou `results`, ou
GeoJSON `features` (les `properties`, plus la `geometry` dans une clé `geometry`). Un autre format
lève une erreur.

### `f_staging_ref(p_table_name text)` → `text` (IMMUTABLE)

Qualifie un nom de staging : il est renvoyé tel quel s'il contient un `.`, sinon il est préfixé par `gn_auto_imports.`.

---

## Transformation

### `f_build_ready_view(p_id_terminal int, p_execute bool DEFAULT true)` → `text`

Génère, et crée si `p_execute`, la vue `gn_auto_imports.v_<alias>_ready`, puis renvoie son SQL.

- `FROM <staging> AS main`.
- Si `explode_column` est défini : `LEFT JOIN LATERAL` sur les éléments du tableau JSON (alias `item`).
  Les éléments strictement identiques sont dédoublonnés. Un parent au tableau vide reste présent
  avec `item` NULL, pour le nettoyage par parent.
- Une jointure `LEFT` ou `INNER` par dépendance directe, sous son `dependency_alias`.
- Une colonne par ligne de `t_mapper_fields` (hors `excluded`), castée vers le type de la colonne cible.
- Colonnes techniques :
  - `_item_idx` : position dans le tableau éclaté ;
  - `_source_key` : la valeur de `order_by_column`, qui sert au découpage par lots ;
  - `_source_update_date` : `GREATEST` de `date_filter_source_field` du terminal et des dépendances
    avec `contributes_update_date`, ou NULL s'il n'y en a aucun. Le cast `::timestamptz::timestamp`
    ramène une date avec fuseau (iNaturalist) à l'heure locale du serveur.
- `WHERE (<row_filter>)` si `row_filter` est renseigné.

Contrôles : le mappeur doit être terminal, sans cycle, avec des champs mappés ; les alias sources
doivent être connus ; l'alias `item` est réservé.

### `f_source_ref(p_alias text, p_column text)` → `text` (IMMUTABLE)

Référence SQL d'une colonne source : `"alias"."col"`, ou pour `item` :
`(item.value #>> '{a,b}')`, à partir du chemin pointé `a.b`.

---

## Push vers la cible

### `f_push_to_target(p_id_terminal int, p_key_from text DEFAULT NULL, p_key_to text DEFAULT NULL, p_wm_max timestamp DEFAULT NULL, p_build_view bool DEFAULT true)` → `jsonb`

Pousse les lignes candidates de `v_<alias>_ready` vers `target_table`. Sans bornes de clé, c'est un
push complet en une transaction (avec sa propre étape de log `push`). Avec des bornes, c'est un lot
appelé par `p_push_to_target`.

Étapes :

1. (re)crée la vue si `p_build_view` ;
2. **candidats** : les lignes avec `_source_update_date` NULL ou `>= last_synthese_push_date`
   (et `<= p_wm_max`), et `_source_key` dans `]p_key_from, p_key_to]`, copiées dans une table temporaire `_push` ;
3. contrôle : les colonnes clés, et la colonne parent si elle est définie, doivent être mappées ;
4. **nettoyage par parent** (`target_parent_column`) : suppression des lignes cibles d'un parent
   repoussé qui ne sont plus dans son tableau ;
5. **garde-fou** : erreur si une clé cible apparaît plusieurs fois ;
6. **hors périmètre** : les clés déjà présentes dans la cible avec un autre périmètre sont retirées
   et comptées (`skipped_other_scope`) ;
7. **DELETE** des lignes du périmètre marquées `'D'` dans `delete_flag_column` ;
8. **UPDATE** des lignes existantes du périmètre **dont au moins une valeur change**
   (`IS DISTINCT FROM`, comparaison textuelle pour json, xml et les types géométriques natifs) ;
9. **INSERT** des clés absentes du périmètre, en ajoutant la valeur de périmètre ;
10. push complet seulement : `last_synthese_push_date = max(_source_update_date)` des candidats,
    remise à NULL de `push_cursor` et `push_wm_max`.

Retour, par exemple :
`{"target": "...", "candidates": n, "inserted": n, "updated": n, "deleted": n, "orphans_deleted": n, "skipped_other_scope": n, "build_s": …, "load_s": …, "delete_s": …, "update_s": …, "insert_s": …}`.

Ne prend pas le verrou consultatif.

### `p_push_to_target(p_id_terminal int, p_batch_size int DEFAULT 10000, INOUT p_stats jsonb DEFAULT NULL)` (procédure)

Push par lots de `p_batch_size` clés sources, avec un COMMIT par lot ; il est repris automatiquement après une interruption.

1. Prend le verrou `(7421, id)` s'il n'est pas déjà détenu. S'il est occupé par une autre session : `NOTICE` et sortie.
2. Recrée la vue.
3. Nouveau push (`push_cursor` NULL) : il fige `push_wm_max = max(_source_update_date)` et pose
   `push_cursor = ''`. Reprise : il réutilise `push_wm_max` et repart après `push_cursor`. COMMIT.
4. Liste les clés candidates restantes (`_push_keys`), puis boucle par tranche ordonnée de clés
   (ordre **texte** de `_source_key`) : `f_push_to_target(id, de, à, wm_max, false)`, cumul des
   compteurs dans `p_stats`, `push_cursor = à`, mise à jour de l'étape `push`, COMMIT.
5. Fin : `last_synthese_push_date = push_wm_max`, `push_cursor` et `push_wm_max` remis à NULL, étape `success`.

Les lignes modifiées à la source au-delà de `push_wm_max` pendant le push sont reprises au run suivant.

---

## Journalisation

### `f_step_start(p_id_mapper int, p_step text, p_details jsonb DEFAULT '{}')` → `int`

Insère une étape (`download` ou `push`) dans `t_sync_step_log`, avec l'`id_run` de la session
(`current_setting('gn_auto_imports.id_run')`) et le pid. Renvoie `id_step`.

### `f_step_update(p_id_step int, p_status text, p_rows bigint, p_chunks int, p_details jsonb DEFAULT '{}', p_error text DEFAULT NULL)` → `void`

Met à jour le statut, le nombre de lignes et de pages ou lots, et fusionne `details`. Pose
`finished_at` sauf pour le statut `running`.

### Tables et vues de logs

| Objet | Contenu |
|---|---|
| `t_sync_step_log` | une ligne par étape (`download`, `push`) : durée, lignes, pages ou lots, `details` jsonb, erreur, pid |
| `t_sync_log` | une ligne par terminal et par run : `success` ou `error`, lignes importées, ignorées, supprimées. Le statut `skipped_incomplete_mapping` est un héritage, il n'est plus utilisé |
| `v_sync_steps` | `t_sync_step_log` + alias, durée en cours, `rows_per_s`, statut `interrupted` si la session a disparu |
| `v_sync_runs` | agrégat par run et par alias : durées et volumes de téléchargement et de push |
| `v_sync_alerts` | les lignes de `t_sync_log` en erreur, ou avec des lignes ignorées hors périmètre |

---

## Fonctions iNaturalist

### `f_inat_expert_ident(p_identifications jsonb, p_user_ids text[])` → `jsonb`

À partir du tableau `identifications` d'une observation iNaturalist, renvoie la détermination
retenue : l'identification **courante** (`current = true`) la plus récente parmi les utilisateurs
`p_user_ids`. Le taxon de la communauté est ignoré. Renvoie NULL si aucun de ces utilisateurs n'a
d'identification courante.

```json
{"taxon_id": 538903, "name": "Bombus", "rank": "subgenus", "nom_cite": "Bombus (Bombus)",
 "cd_nom": 189947, "date": "2026-03-14T13:41:20+01:00", "determiner": "baptiste-hubert"}
```

- `nom_cite` : `Genre (Sous-genre)` pour un sous-genre (le genre est lu dans `taxon.ancestors`),
  `<nom> (complexe)` pour un complexe, le nom tel quel sinon ;
- `determiner` : les experts dont l'identification courante porte sur ce même taxon. Leur nom vient
  de `t_inat_users.display_name` s'il y est, sinon du nom iNaturalist, sinon du login.
  Aujourd'hui : Gilles Mahé (8890201), Baptiste Hubert (9360526) ; Axel Pajot a son nom renseigné dans iNaturalist ;
- `cd_nom` : via `f_inat_taxref`.

Elle est VOLATILE, car elle écrit dans le cache via `f_inat_taxref`. Elle est appelée plusieurs fois
par ligne dans la vue `_ready` : environ 12 s pour 1 200 observations.

### `f_inat_taxref(p_name text, p_rank text, p_genus text DEFAULT NULL)` → `int`

Fait correspondre un taxon iNaturalist avec TaxRef : `lb_nom` = nom, et rang `species` → `ES`,
`subspecies` → `SSES`, `variety` → `VAR`, `form` → `FO`, `genus` → `GN`. On préfère le règne
Animalia et un nom valide. Sans correspondance (sous-genre, complexe, section, ou nom inconnu de
TaxRef), on se rabat sur le genre `p_genus`. Le résultat, même NULL, est mis en cache dans
`t_inat_taxref_cache` : `taxonomie.taxref` n'a pas d'index sur `lb_nom`, et une recherche directe
coûte environ 0,2 s. Il faut vider le cache après une mise à jour de TaxRef.

---

## Utilitaires hors pipeline

### `generate_mapper_fields(_id_mapper int)` (procédure)

Amorce `t_mapper_fields` : pour chaque colonne de la cible qui porte le même nom qu'une colonne du
staging et qui n'a pas encore de mapping, insère un mapping `direct`, ou `geom_geojson` (SRID 4326)
pour `the_geom_4326` et `the_geom_point`. Les colonnes identity et serial, ainsi que la colonne de
périmètre, sont ignorées. Ajoute aussi la constante de périmètre si elle manque. Ne supprime ni ne
modifie aucun mapping existant. Le staging doit déjà exister (un premier téléchargement).

