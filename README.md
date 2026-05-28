# Extraction et vectorisation de la végétation LiDAR

## Description

Ce script permet de produire une couche vectorielle de végétation à partir de dalles LiDAR (`.laz`).

Le traitement :

* extrait uniquement les classes de végétation LiDAR (`3`, `4`, `5`)
* rasterise les classifications avec PDAL
* filtre les petits objets raster isolés
* polygonise les rasters avec GDAL
* dissout les géométries par classe et par dalle
* fusionne l’ensemble des dalles dans un GeoPackage unique
* réalise un dissolve global final par classe de végétation

Le traitement est optimisé pour des volumes importants de données LiDAR.

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

## Dossiers

```bash
INPUT_DIR="/home/utilisateur/Documents/traitement_LIDAR_vegetation/data"

OUTPUT_DIR="output_vegetation_occitanie"
```

---

# Optimisations GDAL / SQLite

```bash
export GDAL_NUM_THREADS=ALL_CPUS

export OGR_SQLITE_SYNCHRONOUS=OFF
export OGR_SQLITE_CACHE=2048
export OGR_SQLITE_PRAGMA="journal_mode=OFF,temp_store=MEMORY"
```

---

# Reconstruction de l’emprise IGN

L’emprise de chaque dalle est reconstruite automatiquement à partir du nom de fichier.

Exemple :

```text
0671_6296.laz
```

Correspond à :

```text
xmin = 671000
ymax = 6296000
xmax = 672000
ymin = 6295000
```

Cette emprise est utilisée pour :

* contraindre la rasterisation PDAL
* éviter les débordements inter-dalles
* limiter les superpositions de géométries

---

# Étapes du traitement

## 1. Extraction des classes 3 à 5

Filtrage des points LiDAR de végétation :

```json
{
  "type": "filters.range",
  "limits": "Classification[3:5]"
}
```

---

## 2. Rasterisation PDAL

Rasterisation directe des classifications LiDAR :

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

### Fonctionnement

Le mode `binmode=true` permet :

* d’utiliser uniquement les points présents dans chaque pixel
* d’éviter les interpolations
* de produire une rasterisation plus stable
* de limiter les artefacts inter-dalles

---

## 3. Filtrage raster

Suppression des petits groupes de pixels isolés :

```bash
gdal_sieve.py
```

### Paramètres

| Paramètre    | Valeur    |
| ------------ | --------- |
| seuil        | 3 pixels  |
| connectivité | 8 voisins |

### Objectifs

* réduire le bruit raster
* accélérer la polygonisation
* réduire le nombre de géométries

---

## 4. Polygonisation

Conversion raster → polygones :

```bash
gdal_polygonize.py
```

---

## 5. Dissolve local par dalle

Fusion des polygones de même classe à l’échelle de chaque dalle.

Correspondance des classes :

| DN | Classe  |
| -- | ------- |
| 3  | basse   |
| 4  | moyenne |
| 5  | haute   |

Le dissolve produit environ :

```text
~3 MULTIPOLYGON par dalle
```

---

## 6. Fusion des dalles

Chaque dalle est ajoutée progressivement dans un GeoPackage intermédiaire :

```text
vegetation_occitanie_dissolved.gpkg
```

Cette étape ne réalise plus de dissolve global à chaque itération afin de :

* limiter fortement les temps de traitement
* éviter les unions géométriques répétitives
* réduire l’utilisation mémoire

---

## 7. Dissolve global final

Un dissolve global unique est exécuté à la fin du traitement :

```sql
GROUP BY classification, classe_vegetation
```

Le dissolve final porte sur environ :

```text
6000 dalles × 3 classes
≈ 18000 géométries
```

Cette approche est beaucoup plus performante qu’un dissolve global exécuté après chaque dalle.

---

# Fichiers générés

## Fichier intermédiaire

```text
vegetation_occitanie_dissolved.gpkg
```

Contient les géométries fusionnées par dalle.

---

## Fichier final

```text
vegetation_occitanie_final.gpkg
```

Contient le dissolve global final par classe de végétation.

---

# Structure des sorties

```text
output_vegetation_occitanie/
├── vegetation_occitanie_dissolved.gpkg
└── vegetation_occitanie_final.gpkg
```

---

# Champs attributaires

| Champ             | Description             |
| ----------------- | ----------------------- |
| classification    | 3 / 4 / 5               |
| classe_vegetation | basse / moyenne / haute |
| geom              | MULTIPOLYGON            |

---

# Exécution

## Rendre le script exécutable

```bash
chmod +x LIDAR.sh
```

## Lancer le traitement

```bash
./LIDAR.sh
```

---

# Résumé du pipeline

```text
LAS / LAZ
   ↓
Filtrage classes 3-5
   ↓
Rasterisation PDAL
   ↓
Filtrage raster (sieve)
   ↓
Polygonisation GDAL
   ↓
Dissolve local par dalle
   ↓
Fusion des dalles
   ↓
Dissolve global final
   ↓
GeoPackage final
```

---

# Structure des fichiers

## Entrée

```text
data/
├── dalle_01.laz
├── dalle_02.laz
├── dalle_03.laz
```

## Sortie

```text
output_vegetation_occitanie/
├── vegetation_occitanie_dissolved.gpkg
└── vegetation_occitanie_final.gpkg
```

---

# Notes

* Le traitement conserve uniquement les classifications LiDAR de végétation.
* Les géométries finales sont stockées en `MULTIPOLYGON`.
* Le filtrage raster réduit fortement les petits artefacts isolés.
* L’emprise IGN permet d’éviter les superpositions inter-dalles.
* Le dissolve global est exécuté une seule fois en fin de traitement afin d’améliorer les performances.
