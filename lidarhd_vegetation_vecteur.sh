#!/bin/bash

# ============================================================
# EXTRACTION ET VECTORISATION DE LA VÉGÉTATION LiDAR
# ============================================================
#
# OBJECTIF
# --------
#
# Générer une couche vectorielle de végétation à partir
# de dalles LiDAR (.laz) en conservant uniquement :
#
#   3 → végétation basse
#   4 → végétation moyenne
#   5 → végétation haute
#
# PIPELINE
# --------
#
#   LAZ
#     ↓
#   Filtrage Classification[3:5]
#     ↓
#   Rasterisation PDAL
#     ↓
#   Filtrage raster (sieve)
#     ↓
#   Polygonisation GDAL
#     ↓
#   Dissolve local par dalle
#     ↓
#   Fusion incrémentale
#     ↓
#   Dissolve global final (optionnel)
#
# SORTIES
# --------
#
# vegetation_occitanie.gpkg
#     → accumulation des dalles
#
# vegetation_occitanie_final.gpkg
#     → dissolve global final
#
# ============================================================

set -euo pipefail

# ============================================================
# CONFIGURATION
# ============================================================

INPUT_DIR="/home/utilisateur/Documents/traitement_LIDAR_vegetation/data"

OUTPUT_DIR="output_vegetation_occitanie"

mkdir -p "$OUTPUT_DIR"

# ------------------------------------------------------------
# PARAMÈTRES DE TRAITEMENT
# ------------------------------------------------------------

# Résolution raster (mètre)
RESOLUTION=0.8

# Taille minimale des groupes de pixels conservés
# (1-2 pixels supprimés)
SIEVE_THRESHOLD=3

# Dissolve global final :
#   true  → active le dissolve global
#   false → conserve uniquement la fusion incrémentale
ENABLE_FINAL_DISSOLVE=false

# ============================================================
# OPTIMISATIONS GDAL / SQLITE
# ============================================================

export GDAL_NUM_THREADS=ALL_CPUS

export OGR_SQLITE_SYNCHRONOUS=OFF
export OGR_SQLITE_CACHE=4096
export OGR_SQLITE_PRAGMA="journal_mode=OFF,temp_store=MEMORY"

# ============================================================
# VÉRIFICATION DES DÉPENDANCES
# ============================================================

DEPENDENCIES=(
    pdal
    ogr2ogr
    gdal_polygonize.py
    gdal_sieve.py
)

for CMD in "${DEPENDENCIES[@]}"; do

    command -v "$CMD" >/dev/null 2>&1 || {
        echo "❌ Dépendance absente : $CMD"
        exit 1
    }

done

# ============================================================
# FICHIERS DE SORTIE
# ============================================================

MERGED_GPKG="$OUTPUT_DIR/vegetation_occitanie.gpkg"

FINAL_GPKG="$OUTPUT_DIR/vegetation_occitanie_final.gpkg"

TMP_FINAL="$OUTPUT_DIR/tmp_final.gpkg"

# Nettoyage anciennes versions
rm -f \
    "$MERGED_GPKG" \
    "$FINAL_GPKG" \
    "$TMP_FINAL"

# ============================================================
# VÉRIFICATION DES DONNÉES
# ============================================================

shopt -s nullglob

FILES=("$INPUT_DIR"/*.laz)

if [ ${#FILES[@]} -eq 0 ]; then
    echo "❌ Aucun fichier .laz trouvé dans : $INPUT_DIR"
    exit 1
fi

# ============================================================
# BOUCLE PRINCIPALE
# ============================================================

for FILE in "${FILES[@]}"; do

    BASENAME=$(basename "$FILE" .laz)

    echo ""
    echo "=================================================="
    echo "➡️ Traitement : $BASENAME"
    echo "=================================================="

    # ========================================================
    # RECONSTRUCTION DE L’EMPRISE IGN
    # ========================================================
    #
    # Exemple :
    #
    #   0671_6296
    #
    # devient :
    #
    #   xmin = 671000
    #   ymax = 6296000
    #
    # ========================================================

    TILE_X=$(echo "$BASENAME" \
        | grep -oE '[0-9]{4}_[0-9]{4}' \
        | cut -d'_' -f1)

    TILE_Y=$(echo "$BASENAME" \
        | grep -oE '[0-9]{4}_[0-9]{4}' \
        | cut -d'_' -f2)

    if [ -z "$TILE_X" ] || [ -z "$TILE_Y" ]; then
        echo "❌ Impossible de lire les coordonnées IGN : $BASENAME"
        exit 1
    fi

    # --------------------------------------------------------
    # Conversion IGN
    # --------------------------------------------------------

    XMIN=$((10#$TILE_X * 1000))
    YMAX=$((10#$TILE_Y * 1000))

    XMAX=$((XMIN + 1000))
    YMIN=$((YMAX - 1000))

    # ========================================================
    # FICHIERS TEMPORAIRES
    # ========================================================

    PIPELINE="$OUTPUT_DIR/pipeline_${BASENAME}.json"

    RASTER="$OUTPUT_DIR/${BASENAME}_classification.tif"

    SIEVE_RASTER="$OUTPUT_DIR/${BASENAME}_classification_sieved.tif"

    POLYGONS="$OUTPUT_DIR/${BASENAME}_polygons.gpkg"

    POLYGONS_CLASS="$OUTPUT_DIR/${BASENAME}_polygons_classified.gpkg"

    # ========================================================
    # ÉTAPE 1 — EXTRACTION + RASTERISATION
    # ========================================================
    #
    # Extraction des classes :
    #
    #   3 → basse
    #   4 → moyenne
    #   5 → haute
    #
    # Raster borné à l’emprise IGN afin de :
    #
    #   - éviter les débordements inter-dalles
    #   - éviter les superpositions
    #   - conserver une grille fixe
    #
    # ========================================================

    cat > "$PIPELINE" <<EOF
{
  "pipeline": [

    {
      "type": "readers.las",
      "filename": "$FILE"
    },

    {
      "type": "filters.range",
      "limits": "Classification[3:5]"
    },

    {
      "type": "writers.gdal",
      "filename": "$RASTER",
      "dimension": "Classification",
      "output_type": "max",
      "resolution": $RESOLUTION,
      "binmode": "true",
      "bounds": "([$XMIN,$XMAX],[$YMIN,$YMAX])"
    }

  ]
}
EOF

    echo "🔹 Extraction + rasterisation..."

    pdal pipeline "$PIPELINE"

    # ========================================================
    # ÉTAPE 2 — FILTRAGE RASTER
    # ========================================================
    #
    # Suppression des petits groupes isolés :
    #
    #   - 1 pixel
    #   - 2 pixels
    #
    # Réduit fortement :
    #
    #   - le bruit
    #   - le nombre de polygones
    #   - le temps de dissolve
    #
    # ========================================================

    echo "🔹 Filtrage raster (sieve)..."

    gdal_sieve.py \
        -st "$SIEVE_THRESHOLD" \
        -8 \
        "$RASTER" \
        "$SIEVE_RASTER"

    # ========================================================
    # ÉTAPE 3 — POLYGONISATION
    # ========================================================

    echo "🔹 Polygonisation..."

    gdal_polygonize.py \
        "$SIEVE_RASTER" \
        -f GPKG \
        "$POLYGONS" \
        polygons

    # ========================================================
    # ÉTAPE 4 — DISSOLVE LOCAL
    # ========================================================
    #
    # Réduction drastique :
    #
    #   milliers de polygones
    #              ↓
    #   ~3 MULTIPOLYGON par dalle
    #
    # ========================================================

    echo "🔹 Dissolve local..."

    ogr2ogr \
        -f GPKG \
        "$POLYGONS_CLASS" \
        "$POLYGONS" \
        -nln vegetation \
        -nlt MULTIPOLYGON \
        -lco GEOMETRY_NAME=geom \
        -lco SPATIAL_INDEX=YES \
        -dialect sqlite \
        -clipsrc "$XMIN" "$YMIN" "$XMAX" "$YMAX" \
        -sql "
        SELECT

            DN AS classification,

            CASE
                WHEN DN = 3 THEN 'basse'
                WHEN DN = 4 THEN 'moyenne'
                WHEN DN = 5 THEN 'haute'
            END AS classe_vegetation,

            CastToMultiPolygon(

                ST_UnaryUnion(
                    ST_Collect(geom)
                )

            ) AS geom

        FROM polygons

        WHERE
            DN IN (3,4,5)
            AND geom IS NOT NULL

        GROUP BY DN
        "

    # ========================================================
    # ÉTAPE 5 — FUSION INCRÉMENTALE
    # ========================================================
    #
    # Accumulation simple des géométries :
    #
    #   - rapide
    #   - peu coûteux
    #   - scalable sur milliers de dalles
    #
    # Aucun dissolve global n’est exécuté ici.
    #
    # ========================================================

    echo "🔹 Fusion incrémentale..."

    # --------------------------------------------------------
    # Première dalle
    # --------------------------------------------------------

    if [ ! -f "$MERGED_GPKG" ]; then

        echo "🔹 Initialisation couche globale..."

        cp "$POLYGONS_CLASS" "$MERGED_GPKG"

    # --------------------------------------------------------
    # Dalles suivantes
    # --------------------------------------------------------

    else

        echo "🔹 Append des géométries..."

        ogr2ogr \
            -f GPKG \
            -update \
            -append \
            "$MERGED_GPKG" \
            "$POLYGONS_CLASS" \
            -nln vegetation \
            -nlt MULTIPOLYGON

    fi

    # ========================================================
    # ÉTAPE 6 — NETTOYAGE
    # ========================================================

    echo "🔹 Nettoyage..."

    rm -f \
        "$PIPELINE" \
        "$RASTER" \
        "$SIEVE_RASTER" \
        "$POLYGONS" \
        "$POLYGONS_CLASS"

    echo "✅ Tuile terminée : $BASENAME"

done

# ============================================================
# ÉTAPE 7 — DISSOLVE GLOBAL FINAL (OPTIONNEL)
# ============================================================

if [ "$ENABLE_FINAL_DISSOLVE" = true ]; then

    echo ""
    echo "=================================================="
    echo "🔹 DISSOLVE GLOBAL FINAL"
    echo "=================================================="

    ogr2ogr \
        -f GPKG \
        "$TMP_FINAL" \
        "$MERGED_GPKG" \
        -nln vegetation \
        -nlt MULTIPOLYGON \
        -lco GEOMETRY_NAME=geom \
        -lco SPATIAL_INDEX=YES \
        -dialect sqlite \
        -sql "
        SELECT

            classification,

            classe_vegetation,

            CastToMultiPolygon(

                ST_UnaryUnion(
                    ST_Collect(geom)
                )

            ) AS geom

        FROM vegetation

        WHERE geom IS NOT NULL

        GROUP BY
            classification,
            classe_vegetation
        "

    mv "$TMP_FINAL" "$FINAL_GPKG"

    echo "✅ Dissolve global terminé"

else

    echo ""
    echo "=================================================="
    echo "ℹ️ Dissolve global ignoré"
    echo "=================================================="

fi

# ============================================================
# FIN
# ============================================================

echo ""
echo "=================================================="
echo "✅ TRAITEMENT TERMINÉ"
echo "=================================================="
