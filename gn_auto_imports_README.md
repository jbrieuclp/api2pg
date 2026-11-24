# Synchronisation GeoNature → GeoNature (`gn_auto_imports`)

Module 100 % PL/pgSQL, dans le schéma `gn_auto_imports` d'une base GeoNature.
Il récupère des données depuis des API JSON et les intègre dans des tables de la base locale
(`gn_synthese.synthese`, `gn_commons.t_validations`, …). Aujourd'hui, deux sources :
- l'API du module Export d'une instance GeoNature distante (Bretagne Vivante) ;
- l'API d'iNaturalist (collection « Bourdons des Pays de la Loire »).

Documentation associée :

- [gn_auto_imports_configuration.md](gn_auto_imports_configuration.md) : tables de configuration, ajout d'un mappeur
- [gn_auto_imports_fonctions.md](gn_auto_imports_fonctions.md) : référence de chaque fonction et procédure

État documenté : 2026-11-24.

---

## 1. Principe

Un **mappeur** (`t_mappers`) correspond à **une ressource d'API** : un export GeoNature, ou une
requête d'observations iNaturalist. Chaque run fait deux étapes :

```
          API distante (GeoNature, iNaturalist…)
                    │  (1) téléchargement : p_download_mapper
                    ▼
  staging  gn_auto_imports.export_<…>    (une colonne text par champ JSON, upsert sur la clé)
                    │
                    │  vue générée v_<alias>_ready : f_build_ready_view
                    │  (jointures des dépendances + mapping t_mapper_fields + casts)
                    ▼
                    │  (2) push : f_push_to_target / p_push_to_target
                    ▼
  table cible  (ex. gn_synthese.synthese)  : DELETE / UPDATE / INSERT sur le périmètre
```

- **Mappeur terminal** (`is_terminal = true`) : il a une table cible. Il est téléchargé **et** poussé.
- **Mappeur intermédiaire** (`is_terminal = false`) : il est seulement téléchargé. Son staging sert
  de jointure à un autre mappeur (ex. les métadonnées des JDD).
- **Dépendances** (`t_mapper_dependencies`) : un mappeur peut joindre le staging d'un autre sous un
  alias (`meta`, `obs`, …). Un run télécharge toute la chaîne de dépendances avant de pousser.

### Configuration actuelle (Bretagne Vivante)

| id | alias | export BV | rôle | cible |
|---|---|---|---|---|
| 7 | `synchro_bv_mtd` | 32 | intermédiaire, métadonnées des JDD | (aucune) |
| 5 | `synchro_bv` | 31 | terminal, observations | `gn_synthese.synthese`, JDD 3144, id_source 8 |
| 12 | `synchro_bv_validations` | 33 | terminal, historique des validations | `gn_commons.t_validations` |

Dépendances :

- `synchro_bv` joint `synchro_bv_mtd` sous l'alias `meta` (LEFT JOIN sur `unique_dataset_id`).
  Le JSON du JDD est ajouté dans `additional_data.dataset_json`.
- `synchro_bv_validations` joint `synchro_bv` sous l'alias `obs` (INNER JOIN `uuid_attached_row = unique_id_sinp`).
  Il éclate `validation_history_json` (une ligne par validation) et il est filtré par `row_filter`
  sur les observations présentes dans la synthèse avec `id_dataset = 3144`.

Lancer `synchro_bv_validations` déclenche donc toute la chaîne : téléchargement de 7, puis 5, puis 12,
puis push de 5 et enfin push de 12.

### Configuration actuelle (iNaturalist)

| id | alias | source | rôle | cible |
|---|---|---|---|---|
| 13 | `inat_bourdons_pdl` | `api.inaturalist.org/v1/observations`, collection 276813 | terminal, observations | `gn_synthese.synthese`, JDD 3159, source 9 « API iNaturalist » |
| 14 | `inat_bourdons_pdl_medias` | **pas de téléchargement** : relit le staging du 13 | terminal, photos | `gn_commons.t_medias` |

- **Périmètre** : les observations de la collection 276813 (« Bourdons des Pays de la Loire » : Bombus,
  Pays de la Loire, qualité research ou needs_id, avec photo) **identifiées par au moins un des 3 experts**
  `ident_user_id = 7441090 (axelpajot), 8890201 (gilles-mahe), 9360526 (baptiste-hubert)`.
- **Taxon** : la détermination des experts fait foi, et non le taxon de la communauté iNaturalist.
  `f_inat_expert_ident` retient, parmi les identifications **courantes** des 3 experts, le taxon proposé par
  **le plus grand nombre d'experts** (à égalité : le plus récemment proposé). Elle renvoie aussi `n_experts`,
  `n_accord` (experts d'accord sur ce taxon) et `autres_taxons` (taxons proposés par les autres experts).
  `determiner` contient les experts qui ont proposé le taxon retenu, avec leurs noms d'affichage de
  `t_inat_users`. Le taxon de la communauté est conservé dans `additional_data.taxon_communaute`.
- **Filtre (`row_filter`, depuis le 2026-11-24)** : la détermination retenue doit être à l'espèce ou à la
  sous-espèce, **au moins 2 experts** doivent être d'accord sur ce taxon (un 3ᵉ expert en désaccord n'exclut
  pas l'observation), l'observation ne doit pas être floutée (`obscured = 'false'`) et la précision publique
  doit être inférieure à 500 m (précision absente = acceptée). Au 2026-11-24 : 412 observations retenues.
  Les observations déjà importées qui ne remplissent plus ces conditions **ne sont pas retirées**
  automatiquement de la synthèse (176 au 2026-11-24), ni leurs photos.
- **Commentaire (`comment_description`)** : description iNaturalist, puis, sur des lignes séparées,
  « Un autre nom a été donné sous iNaturalist : <taxon final iNat> » si le taxon de l'observation iNat
  diffère du taxon des experts, et « Désaccord d'expert : <taxon> (<expert>) » si un expert a proposé un
  autre taxon (y compris un rang supérieur, par ex. le genre).
- **Statut de validation** : non renseigné, donc la valeur par défaut de la synthèse s'applique.
- **Pagination keyset** (`id_above`) et filtre incrémental `updated_since` en ISO 8601, avec une pause
  de 1 s entre deux requêtes (consigne de l'API iNaturalist).

- **Photos (mappeur 14)** : `download_enabled = false`, `table_name` = staging du 13, éclatement de la
  colonne `photos` (une ligne par photo). Il dépend du 13 (alias `obs`) : lancer le 14 télécharge et pousse
  d'abord les observations, puis leurs photos. `row_filter` : seulement les observations présentes dans la
  synthèse (JDD 3159). Mapping : `unique_id_media` = UUID v5 de `https://www.inaturalist.org/photos/<id>`
  (stable), `uuid_attached_row` = UUID de l'observation (= `unique_id_sinp`), `id_table_location = 1`,
  type « Photo » (`TYPE_MEDIA` 2), `media_url` = URL iNat avec `square` remplacé par `original`, `author`
  = nom tiré de l'attribution, `description_fr` = attribution (licence) et lien vers la photo,
  `is_public = true` pour toutes les photos, y compris les 327 « all rights reserved » (choix du 2026-11-24).
  `target_parent_column = uuid_attached_row` : une photo retirée d'une observation sur iNaturalist est
  supprimée de `t_medias` au push suivant. **Attention :** ce nettoyage supprime aussi toute autre ligne de
  `t_medias` rattachée à une observation iNat poussée (ex. un média saisi à la main).
  Au 2026-11-24 : 1 556 photos pour 588 observations.

Pour modifier la liste des experts, il faut changer `api_params.ident_user_id` **et** le tableau
`'{8890201,9360526,7441090}'`. Ce tableau est écrit dans `row_filter` et dans les expressions de
`t_mapper_fields` (`nom_cite`, `cd_nom`, `determiner`, `additional_data`).

---

## 2. Utilisation

Connexion : `psql -h <hôte> -p <port> -U <utilisateur> -d <base>`, avec un utilisateur qui a les droits d'écriture sur `gn_auto_imports` et sur les tables cibles.

### 2.1 Run courant (incrémental)

```sql
-- Tous les terminaux actifs
CALL gn_auto_imports.p_run_all();

-- Un seul terminal (et sa chaîne)
CALL gn_auto_imports.p_run_all('synchro_bv');
```

`p_run_all` traite chaque chaîne dans un sous-bloc d'exception. Si une chaîne échoue, l'erreur est
journalisée dans `t_sync_log` (status `error`) et un `WARNING` est levé, puis les autres chaînes
continuent. Il n'y a **aucun COMMIT intermédiaire** : le travail n'est validé qu'à la fin du `CALL`.
Pour de gros volumes, utiliser plutôt `p_run_terminal` (voir 2.2).

Un mappeur téléchargé pour une chaîne n'est pas re-téléchargé pour la suivante, ni un terminal
déjà poussé.

### 2.2 Chargement initial ou gros volume (avec COMMIT)

```sql
-- p_run_terminal(id_terminal, commit_per_page, done, push_batch_size)
CALL gn_auto_imports.p_run_terminal(5,  true, '{}', 10000);
CALL gn_auto_imports.p_run_terminal(12, true, '{}', 10000);
CALL gn_auto_imports.p_run_terminal(14, true, '{}', 10000);   -- observations iNat (13) puis photos (14)
```

- `commit_per_page = true` : COMMIT après chaque page API téléchargée et après chaque terminal poussé.
- `push_batch_size = 10000` : push par lots de 10 000 clés, avec un COMMIT par lot (`p_push_to_target`).
- Le `CALL` doit être lancé **hors d'un bloc de transaction** (psql en autocommit, pas de `BEGIN`),
  sinon les COMMIT échouent.
- **Reprise automatique** après une interruption (coupure, Ctrl-C, erreur) : il suffit de relancer la même commande.
  - téléchargement : il reprend à partir de `last_imported_id` (paramètre `id_filter_query_param`)
    tant que la synchro n'a jamais abouti (`last_synchronization_date` NULL) ;
  - push par lots : il reprend après `push_cursor`, avec la même borne de watermark (`push_wm_max`).

### 2.3 Suivi

```sql
-- Un résumé par run et par mappeur
SELECT * FROM gn_auto_imports.v_sync_runs ORDER BY id_run DESC, started_at LIMIT 20;

-- Le détail des étapes (download / push), avec la progression en direct
SELECT id_run, alias, step, status, duration, n_rows, n_chunks, rows_per_s, details
FROM gn_auto_imports.v_sync_steps ORDER BY id_step DESC LIMIT 20;

-- Les erreurs et les lignes ignorées hors périmètre
SELECT * FROM gn_auto_imports.v_sync_alerts LIMIT 20;

-- L'état des points de reprise
SELECT id_mapper, alias, last_synchronization_date, last_imported_id,
       last_synthese_push_date, push_cursor, push_wm_max
FROM gn_auto_imports.t_mappers ORDER BY id_mapper;
```

Dans `v_sync_steps`, une étape `running` dont la session n'existe plus s'affiche en `interrupted`.

Pendant un run, `t_sync_step_log` est mis à jour à chaque page ou lot. Avec `commit_per_page = true`,
la progression est visible depuis une autre session.

### 2.4 Exécutions concurrentes

Chaque terminal d'une chaîne est protégé par un verrou consultatif de session
`pg_advisory_lock(7421, id_mapper)`. Si un second run touche un terminal déjà en cours, il s'arrête
avec un `NOTICE ... déjà en cours d'exécution, ignoré`, sans erreur.

Les verrous de session sont libérés à la fin du run, ou à la déconnexion de la session. Si un
`p_run_terminal` appelé directement échoue, la session garde le verrou ; on peut le relancer dans la
même session (le verrou est réutilisé) ou se déconnecter.

Attention : le DDL sur `t_mappers` (`ALTER TABLE …`) attend la fin d'un run en cours.

### 2.5 Opérations courantes

**Voir le SQL de la vue générée sans la créer :**

```sql
SELECT gn_auto_imports.f_build_ready_view(5, false);
```

**Prévisualiser les données prêtes à pousser :**

```sql
SELECT gn_auto_imports.f_build_ready_view(5);       -- (re)crée la vue
SELECT * FROM gn_auto_imports.v_synchro_bv_ready LIMIT 10;
```

**Pousser sans re-télécharger** (le staging est déjà à jour) :

```sql
SELECT gn_auto_imports.f_push_to_target(5);          -- en une transaction
CALL   gn_auto_imports.p_push_to_target(5, 10000);   -- par lots avec COMMIT
```

`f_push_to_target`, appelée seule, ne prend pas le verrou consultatif. Ne pas la lancer pendant un run.

**Forcer un re-push complet** (ex. après une modification du mapping) :

```sql
UPDATE gn_auto_imports.t_mappers
SET last_synthese_push_date = NULL, push_cursor = NULL, push_wm_max = NULL
WHERE id_mapper = 5;
```

Le push suivant reprend toutes les lignes du staging. Seules les lignes dont une valeur change sont
réécrites (UPDATE conditionnel), donc les triggers de la synthèse ne sont pas déclenchés pour rien.

**Forcer un re-téléchargement complet :**

```sql
UPDATE gn_auto_imports.t_mappers
SET last_synchronization_date = NULL, last_imported_id = NULL
WHERE id_mapper = 5;
```

Le staging n'est pas vidé : les lignes sont mises à jour par upsert. Pour repartir d'un staging
propre, il faut aussi le supprimer (`DROP TABLE gn_auto_imports.export_synchro_bv CASCADE`, ce qui
supprime aussi les vues `_ready`, recréées au push suivant). Il sera recréé au téléchargement.

**Désactiver un mappeur :** `UPDATE gn_auto_imports.t_mappers SET active = false WHERE id_mapper = …;`
Une chaîne qui a besoin d'un mappeur inactif échoue : `mappeur(s) inactif(s) requis`.

---

## 3. Déploiement sur une autre base

Les scripts sont séparés en trois niveaux :

| script | contenu | à lancer |
|---|---|---|
| `gn_auto_imports_deploy_01_structure.sql` | **cœur générique** : schéma, tables de configuration et de logs, vues, fonctions du pipeline (téléchargement, vue `_ready`, push) | toujours, en premier, sur une base où `gn_auto_imports` n'existe pas |
| `gn_auto_imports_module_<source>.sql` | **module complémentaire** propre à une source : ses tables et fonctions utilisées par les expressions des mappeurs. Aujourd'hui : `gn_auto_imports_module_inaturalist.sql` | si la source est utilisée, après le cœur |
| `gn_auto_imports_deploy_0x_config_<source>.sql` | **configuration** : mappeurs, champs, dépendances | après le cœur et le module éventuel |

```bash
psql -h <hôte> -p <port> -U <user> -d <base> -f gn_auto_imports_deploy_01_structure.sql
# Bretagne Vivante (pas de module : configuration seule)
psql -h <hôte> -p <port> -U <user> -d <base> -f gn_auto_imports_deploy_02_config_bretagne_vivante.sql
# iNaturalist : module, puis configuration
psql -h <hôte> -p <port> -U <user> -d <base> -f gn_auto_imports_module_inaturalist.sql
psql -h <hôte> -p <port> -U <user> -d <base> -f gn_auto_imports_deploy_03_config_inaturalist.sql
```

- `01_structure` : extensions `http` et `postgis` si elles sont absentes, puis le schéma, les tables
  de configuration et de logs, les vues et les fonctions génériques. Une seule transaction. Aucun droit n'est
  attribué à d'autres rôles : à chaque structure de faire ses `GRANT` selon ses besoins. Il ne contient rien de propre à une source.
- `module_inaturalist` : tables `t_inat_taxref_cache` et `t_inat_users`, fonctions `f_inat_taxref` et
  `f_inat_expert_ident`. Il vérifie que le cœur est installé. **Il peut être relancé** (tables créées si
  absentes, fonctions remplacées) : c'est aussi la façon de mettre à jour ces fonctions sur une base existante.
- `02_config_bretagne_vivante` : les 3 mappeurs, leurs champs et leurs dépendances, avec l'état de
  synchro remis à zéro. **Il contient les tokens des exports.** Il dépend du JDD 3144, de la
  source 8 et des types de zonage 25, 46, 47 et 34 : à adapter sur une autre base.
- `03_config_inaturalist` : les mappeurs `inat_bourdons_pdl` (observations) et `inat_bourdons_pdl_medias`
  (photos), et les noms des experts dans `t_inat_users`. Il crée la source « API iNaturalist » si elle
  est absente, et il dépend du JDD 3159.
- Les scripts 02 et 03 sont indépendants l'un de l'autre.
- Les stagings `export_*` et les vues `v_*_ready` ne sont pas créés par les scripts : ils le sont au premier run.

**Ajouter une nouvelle source avec des fonctions spécifiques** : mettre ses tables et fonctions dans
un nouveau `gn_auto_imports_module_<source>.sql` (sur le modèle du module iNaturalist : vérification du
cœur, `CREATE TABLE IF NOT EXISTS`, `CREATE OR REPLACE FUNCTION`), et ses mappeurs
dans un script de configuration. Ne pas les ajouter au cœur.

---

## 4. Points d'attention

- **Lignes ignorées hors périmètre.** Si une clé (ex. `unique_id_sinp`) existe déjà dans la cible avec
  un autre périmètre (autre `id_dataset`), elle n'est ni insérée ni modifiée. Elle est seulement comptée
  dans `skipped_other_scope` (`t_sync_log.rows_skipped_other_dataset`, visible dans `v_sync_alerts`).
  C'est le cas, par exemple, d'observations déjà importées à la main dans d'autres JDD de la base.
- **Suppressions.** Une ligne n'est supprimée de la cible que si l'export la signale par
  `last_action = 'D'` (`delete_flag_column`). Le staging n'est jamais purgé : une ligne qui disparaît
  simplement de l'export reste dans la cible.
- **Exports sans filtre de date.** Les exports 32 (`synchro_bv_mtd`) et 33 (`synchro_bv_validations`)
  n'ont pas de `date_filter_query_param` : ils sont retéléchargés entièrement à chaque run
  (environ 420 000 lignes pour les validations, soit quelques minutes). Côté push, `synchro_bv_validations`
  n'a pas de date de mise à jour (`_source_update_date` NULL) : toutes ses lignes sont candidates à
  chaque run, mais seules les nouveautés et les changements sont écrits.
- **Recouvrement de 5 minutes.** Le téléchargement incrémental demande les lignes modifiées depuis
  `last_synchronization_date - 5 min`, ce qui évite de rater des lignes en cas de décalage d'horloge.
- **iNaturalist ne signale pas les suppressions.** Une observation supprimée sur iNaturalist, ou qui
  sort du filtre (taxon hors Bombus, qualité passée en `casual`, détermination d'expert redescendue au genre),
  reste dans la synthèse telle qu'au dernier passage.
- **Cache TaxRef iNaturalist.** La correspondance taxon iNat → `cd_nom` est mise en cache dans
  `t_inat_taxref_cache` (TaxRef n'a pas d'index sur `lb_nom`). Après une mise à jour de TaxRef :
  `TRUNCATE gn_auto_imports.t_inat_taxref_cache;`, puis forcer un re-push (voir 2.5).
- **Pas d'ordonnanceur.** pg_cron n'est pas installé. Les runs sont lancés à la main ou par un cron
  système qui appelle `psql`.
- **Sauvegarde de l'ancien pipeline.** Les anciennes fonctions et colonnes supprimées le 2026-11-19
  sont dans `backup_gn_auto_imports_old_functions_2026-11-19.sql`.
