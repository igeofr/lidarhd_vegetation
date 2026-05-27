# Extraction et vectorisation de la végétation LiDAR

## Description

Ce script permet de :

- extraire les classes de végétation LiDAR (`3`, `4`, `5`)
- rasteriser les classifications avec PDAL
- polygoniser les rasters avec GDAL
- dissoudre les géométries par classe
- fusionner progressivement toutes les dalles dans un GeoPackage unique

Le traitement est optimisé pour de grands volumes de données LiDAR.

---

# Classes conservées

| Classification | Description |
|---|---|
| 3 | Végétation basse |
| 4 | Végétation moyenne |
| 5 | Végétation haute |

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

## Optimisations GDAL / SQLite

```bash
export GDAL_NUM_THREADS=ALL_CPUS

export OGR_SQLITE_SYNCHRONOUS=OFF
export OGR_SQLITE_CACHE=2048
export OGR_SQLITE_PRAGMA="journal_mode=OFF,temp_store=MEMORY"
```

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

## 2. Rasterisation

Rasterisation directe des classifications LiDAR :

```json
{
  "type": "writers.gdal",
  "dimension": "Classification",
  "output_type": "max",
  "resolution": 0.2
}
```

### Paramètres

| Paramètre | Valeur |
|---|---|
| dimension | Classification |
| output_type | max |
| resolution | 0.2 m |

---

## 3. Filtrage

Suppression des groupes de moins de 3 pixels ayant une connectivité de 8 voisins :

```bash
gdal_sieve.py
```

---

## 4. Polygonisation

Conversion raster → polygones :

```bash
gdal_polygonize.py
```

---

## 5. Dissolve local

Fusion des polygones de même classe par dalle :

```sql
GROUP BY DN
```

Correspondance des classes :

| DN | Classe |
|---|---|
| 3 | basse |
| 4 | moyenne |
| 5 | haute |

---

## 6. Fusion incrémentale

Chaque dalle est ajoutée progressivement au fichier final :

```text
vegetation_occitanie_dissolved.gpkg
```

Un mini dissolve est effectué après chaque ajout afin de :

- limiter la mémoire utilisée
- éviter un dissolve global massif
- accélérer le traitement

---

# Fichier final

## Sortie

```text
output_vegetation_occitanie/
└── vegetation_occitanie_dissolved.gpkg
```

## Champs attributaires

| Champ | Description |
|---|---|
| classification | 3 / 4 / 5 |
| classe_vegetation | basse / moyenne / haute |
| geom | MULTIPOLYGON |

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
LAS/LAZ
   ↓
Filtrage classes 3-5
   ↓
Rasterisation PDAL
   ↓
filtrage GDAL
   ↓
Polygonisation GDAL
   ↓
Dissolve local
   ↓
Fusion incrémentale
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
└── vegetation_occitanie_dissolved.gpkg
```

---

# Notes

- Le traitement conserve uniquement les classifications LiDAR de végétation.
- Le fichier final est maintenu sous forme de `MULTIPOLYGON`.
- La fusion incrémentale permet de traiter efficacement un grand nombre de dalles.
- Le dissolve local réduit fortement le nombre de géométries intermédiaires.
