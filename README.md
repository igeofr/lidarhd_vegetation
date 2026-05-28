# Extraction et vectorisation de la végétation LiDAR

## Description

Ce script permet de produire une couche vectorielle de végétation à partir de dalles LiDAR `.laz`.

Le traitement conserve uniquement les classes de végétation :

* `3` → végétation basse
* `4` → végétation moyenne
* `5` → végétation haute

Le pipeline utilise :

* PDAL pour la rasterisation
* GDAL pour le filtrage raster et la polygonisation
* OGR/GPKG pour les traitements vectoriels

Le traitement est optimisé pour manipuler plusieurs milliers de dalles LiDAR.

<img width="1103" height="756" alt="image" src="https://github.com/user-attachments/assets/96e0a6bc-9ad3-4e43-981c-e91af1d16cb5" />

---

# Pipeline de traitement

```text
LAZ
  ↓
Filtrage Classification[3:5]
  ↓
Rasterisation PDAL
  ↓
Filtrage raster (sieve)
  ↓
Polygonisation GDAL
  ↓
Dissolve local par dalle
  ↓
Fusion incrémentale
  ↓
Dissolve global final (optionnel)
```

---

# Classes conservées

| Classification | Description        |
| -------------- | ------------------ |
| 3              | Végétation basse   |
| 4              | Végétation moyenne |
| 5              | Végétation haute   |

---

# Dépendances

## PDAL

```bash
sudo apt install pdal
```

## GDAL

```bash
sudo apt install gdal-bin
```

---

# Configuration

## Répertoires

```bash
INPUT_DIR="/home/utilisateur/Documents/traitement_LIDAR_vegetation/data"

OUTPUT_DIR="output_vegetation_occitanie"
```

---

## Paramètres principaux

```bash
# Résolution raster
RESOLUTION=0.8

# Taille minimale des groupes de pixels conservés
SIEVE_THRESHOLD=3

# Dissolve global final
ENABLE_FINAL_DISSOLVE=false
```

---

## Optimisations GDAL / SQLite

```bash
export GDAL_NUM_THREADS=ALL_CPUS

export OGR_SQLITE_SYNCHRONOUS=OFF

export OGR_SQLITE_CACHE=4096

export OGR_SQLITE_PRAGMA="journal_mode=OFF,temp_store=MEMORY"
```

---

# Reconstruction automatique des emprises IGN

Le script reconstruit automatiquement l’emprise de chaque dalle à partir du nom du fichier.

## Exemple

```text
0671_6296.laz
```

devient :

```text
xmin = 671000
ymax = 6296000
xmax = 672000
ymin = 6295000
```

Cette emprise est utilisée directement dans `writers.gdal` afin de :

* éviter les débordements inter-dalles
* garantir une grille raster fixe
* limiter les superpositions de géométries

---

# Étapes du traitement

## 1. Filtrage des classes LiDAR

Extraction des classifications de végétation :

```json
{
  "type": "filters.range",
  "limits": "Classification[3:5]"
}
```

---

## 2. Rasterisation PDAL

Rasterisation des classifications LiDAR :

```json
{
  "type": "writers.gdal",
  "dimension": "Classification",
  "output_type": "max",
  "resolution": 0.8,
  "binmode": "true"
}
```

### Paramètres

| Paramètre   | Valeur         |
| ----------- | -------------- |
| dimension   | Classification |
| output_type | max            |
| resolution  | 0.8 m          |
| binmode     | true           |

---

## 3. Filtrage raster

Suppression des petits groupes isolés de pixels :

```bash
gdal_sieve.py
```

### Paramètres

| Paramètre | Description                        |
| --------- | ---------------------------------- |
| `-st 3`   | suppression des groupes < 3 pixels |
| `-8`      | connectivité 8 voisins             |

Ce filtrage permet :

* de réduire le bruit
* d’accélérer la polygonisation
* de limiter fortement le nombre de géométries

---

## 4. Polygonisation

Conversion raster → polygones :

```bash
gdal_polygonize.py
```

---

## 5. Dissolve local par dalle

Fusion des polygones de même classe dans chaque dalle :

```sql
GROUP BY DN
```

Correspondance des classes :

| DN | Classe  |
| -- | ------- |
| 3  | basse   |
| 4  | moyenne |
| 5  | haute   |

Le dissolve local réduit fortement le nombre de géométries :

```text
milliers de polygones
          ↓
~3 MULTIPOLYGON par dalle
```

---

## 6. Fusion incrémentale

Les géométries de chaque dalle sont ajoutées progressivement dans :

```text
vegetation_occitanie.gpkg
```

Cette méthode permet :

* d’éviter un dissolve global à chaque itération
* de réduire fortement les temps de traitement
* de gérer plusieurs milliers de dalles

---

## 7. Dissolve global final (optionnel)

Le dissolve global peut être activé via :

```bash
ENABLE_FINAL_DISSOLVE=true
```

Le traitement fusionne alors toutes les géométries par classe :

```sql
GROUP BY classification, classe_vegetation
```

Le résultat est enregistré dans :

```text
vegetation_occitanie_final.gpkg
```

Ce traitement peut être long sur de très gros volumes de données.

---

# Fichiers de sortie

## Fusion incrémentale

```text
output_vegetation_occitanie/
└── vegetation_occitanie.gpkg
```

## Dissolve global final

```text
output_vegetation_occitanie/
└── vegetation_occitanie_final.gpkg
```

---

# Structure des attributs

| Champ             | Description             |
| ----------------- | ----------------------- |
| classification    | 3 / 4 / 5               |
| classe_vegetation | basse / moyenne / haute |
| geom              | MULTIPOLYGON            |

---

# Exécution

## Rendre le script exécutable

```bash
chmod +x LIDAR_veg_IGN.sh
```

## Lancer le traitement

```bash
./LIDAR_veg_IGN.sh
```

---

# Structure des données

## Entrée

```text
data/
├── 0671_6296.laz
├── 0672_6296.laz
├── 0673_6296.laz
```

## Sortie

```text
output_vegetation_occitanie/
├── vegetation_occitanie.gpkg
└── vegetation_occitanie_final.gpkg
```

---

# Notes

* Le traitement conserve uniquement les classes LiDAR de végétation.
* Les rasters sont bornés automatiquement aux emprises IGN.
* Le filtrage raster réduit fortement le bruit et le nombre de géométries.
* Le dissolve local permet de limiter la complexité géométrique.
* La fusion incrémentale est beaucoup plus rapide qu’un dissolve global à chaque dalle.
* Le dissolve global final est optionnel afin de conserver de bonnes performances sur de gros volumes de données.
