#!/bin/bash

# ============================================================
# EXTRACTION ET VECTORISATION DE LA VÉGÉTATION LiDAR
# VERSION PARALLÉLISÉE
# ============================================================
#
# OBJECTIF
# --------
#
# Traitement massif de dalles LiDAR (.laz)
# avec parallélisation complète par dalle.
#
# Chaque dalle produit :
#
#   → 1 GeoPackage indépendant
#
# La fusion finale est exécutée UNE SEULE FOIS.
#
# ============================================================
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
#   Polygonisation
#     ↓
#   Dissolve local
#     ↓
#   1 GPKG par dalle
#     ↓
#   Fusion finale
#     ↓
#   Dissolve global optionnel
#
# ============================================================

set -euo pipefail

# ============================================================
# CONFIGURATION
# ============================================================

INPUT_DIR="/home/utilisateur/Documents/traitement_LIDAR_vegetation/data"

OUTPUT_DIR="output_vegetation_occitanie"

TILES_DIR="$OUTPUT_DIR/tiles"

mkdir -p "$OUTPUT_DIR"
mkdir -p "$TILES_DIR"

# ------------------------------------------------------------
# PARAMÈTRES
# ------------------------------------------------------------

# Résolution raster
RESOLUTION=0.8

# Suppression groupes < N pixels
SIEVE_THRESHOLD=3

# Nombre de jobs parallèles
PARALLEL_JOBS=8

# Dissolve global final
ENABLE_FINAL_DISSOLVE=false

# ============================================================
# OPTIMISATIONS GDAL / SQLITE
# ============================================================

export GDAL_NUM_THREADS=ALL_CPUS

export OGR_SQLITE_SYNCHRONOUS=OFF
export OGR_SQLITE_CACHE=4096
export OGR_SQLITE_PRAGMA="journal_mode=OFF,temp_store=MEMORY"

# ============================================================
# DÉPENDANCES
# ============================================================

DEPENDENCIES=(
    pdal
    ogr2ogr
    ogrmerge.py
    gdal_polygonize.py
    gdal_sieve.py
    parallel
)

for CMD in "${DEPENDENCIES[@]}"; do

    command -v "$CMD" >/dev/null 2>&1 || {
        echo "❌ Dépendance absente : $CMD"
        exit 1
    }

done

# ============================================================
# VÉRIFICATION DES DONNÉES
# ============================================================

shopt -s nullglob

FILES=("$INPUT_DIR"/*.laz)

if [ ${#FILES[@]} -eq 0 ]; then
    echo "❌ Aucun fichier .laz trouvé"
    exit 1
fi

# ============================================================
# FONCTION DE TRAITEMENT
# ============================================================

process_tile() {

    FILE="$1"

    BASENAME=$(basename "$FILE" .laz)

    echo ""
    echo "=================================================="
    echo "➡️ Traitement : $BASENAME"
    echo "=================================================="

    # ========================================================
    # RECONSTRUCTION EMPRISE IGN
    # ========================================================

    TILE_X=$(echo "$BASENAME" \
        | grep -oE '[0-9]{4}_[0-9]{4}' \
        | cut -d'_' -f1)

    TILE_Y=$(echo "$BASENAME" \
        | grep -oE '[0-9]{4}_[0-9]{4}' \
        | cut -d'_' -f2)

    if [ -z "$TILE_X" ] || [ -z "$TILE_Y" ]; then
        echo "❌ Impossible de lire : $BASENAME"
        return 1
    fi

    XMIN=$((10#$TILE_X * 1000))
    YMAX=$((10#$TILE_Y * 1000))

    XMAX=$((XMIN + 1000))
    YMIN=$((YMAX - 1000))

    # ========================================================
    # FICHIERS TEMPORAIRES
    # ========================================================

    PIPELINE="$OUTPUT_DIR/pipeline_${BASENAME}.json"

    RASTER="$OUTPUT_DIR/${BASENAME}.tif"

    SIEVE_RASTER="$OUTPUT_DIR/${BASENAME}_sieved.tif"

    POLYGONS="$OUTPUT_DIR/${BASENAME}_polygons.gpkg"

    TILE_GPKG="$TILES_DIR/${BASENAME}.gpkg"

    # Nettoyage ancien résultat
    rm -f "$TILE_GPKG"

    # ========================================================
    # PIPELINE PDAL
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

    # ========================================================
    # ÉTAPE 1 — RASTERISATION
    # ========================================================

    echo "🔹 Rasterisation..."

    pdal pipeline "$PIPELINE"

    # ========================================================
    # ÉTAPE 2 — SIEVE
    # ========================================================

    echo "🔹 Filtrage raster..."

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

    echo "🔹 Dissolve local..."

    ogr2ogr \
        -f GPKG \
        "$TILE_GPKG" \
        "$POLYGONS" \
        -nln vegetation \
        -nlt MULTIPOLYGON \
        -lco GEOMETRY_NAME=geom \
        -lco SPATIAL_INDEX=YES \
        -dialect sqlite \
        -clipsrc "$XMIN" "$YMIN" "$XMAX" "$YMAX" \
        -sql "
        SELECT
            '$BASENAME' AS dalle,
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
    # NETTOYAGE
    # ========================================================

    rm -f \
        "$PIPELINE" \
        "$RASTER" \
        "$SIEVE_RASTER" \
        "$POLYGONS"

    echo "✅ Tuile terminée : $BASENAME"
}

export -f process_tile

export OUTPUT_DIR
export TILES_DIR
export RESOLUTION
export SIEVE_THRESHOLD

# ============================================================
# LANCEMENT PARALLÈLE
# ============================================================

echo ""
echo "=================================================="
echo "🚀 TRAITEMENT PARALLÈLE"
echo "=================================================="

parallel \
    -j "$PARALLEL_JOBS" \
    process_tile ::: "${FILES[@]}"

# ============================================================
# FUSION FINALE
# ============================================================

echo ""
echo "=================================================="
echo "🔹 FUSION FINALE"
echo "=================================================="

MERGED_GPKG="$OUTPUT_DIR/vegetation_occitanie.gpkg"

rm -f "$MERGED_GPKG"

ogrmerge.py \
    -single \
    -f GPKG \
    -o "$MERGED_GPKG" \
    "$TILES_DIR"/*.gpkg

# ============================================================
# DISSOLVE GLOBAL FINAL (OPTIONNEL)
# ============================================================

if [ "$ENABLE_FINAL_DISSOLVE" = true ]; then

    echo ""
    echo "=================================================="
    echo "🔹 DISSOLVE GLOBAL FINAL"
    echo "=================================================="

    FINAL_GPKG="$OUTPUT_DIR/vegetation_occitanie_final.gpkg"

    TMP_FINAL="$OUTPUT_DIR/tmp_final.gpkg"

    rm -f "$FINAL_GPKG"
    rm -f "$TMP_FINAL"

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

fi

# ============================================================
# FIN
# ============================================================

echo ""
echo "=================================================="
echo "✅ TRAITEMENT TERMINÉ"
echo "=================================================="
