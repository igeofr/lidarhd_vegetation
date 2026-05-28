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
#   Dissolve global final
#
# SORTIES
# --------
#
#   vegetation_occitanie_dissolved.gpkg
#       → accumulation des dalles
#
#   vegetation_occitanie_final.gpkg
#       → dissolve global final
#
# ============================================================

set -euo pipefail

# ============================================================
# CONFIGURATION
# ============================================================

INPUT_DIR="/home/utilisateur/Documents/traitement_LIDAR_vegetation/data"

OUTPUT_DIR="output_vegetation_occitanie"

mkdir -p "$OUTPUT_DIR"

# ============================================================
# OPTIMISATIONS GDAL / SQLITE
# ============================================================

# Utilisation de tous les CPU disponibles
export GDAL_NUM_THREADS=ALL_CPUS

# Optimisations GeoPackage / SQLite
export OGR_SQLITE_SYNCHRONOUS=OFF
export OGR_SQLITE_CACHE=2048
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

MERGED_GPKG="$OUTPUT_DIR/vegetation_occitanie_dissolved.gpkg"

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
    echo "❌ Aucun fichier .laz trouvé"
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

    TILE_X=$(echo "$BASENAME" | grep -oE '[0-9]{4}_[0-9]{4}' | cut -d'_' -f1)

    TILE_Y=$(echo "$BASENAME" | grep -oE '[0-9]{4}_[0-9]{4}' | cut -d'_' -f2)

    if [ -z "$TILE_X" ] || [ -z "$TILE_Y" ]; then
        echo "❌ Impossible de lire les coordonnées de dalle"
        exit 1
    fi

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
    # Filtrage des classes :
    #
    #   3 = basse
    #   4 = moyenne
    #   5 = haute
    #
    # Rasterisation bornée à l’emprise IGN
    # pour éviter les débordements inter-dalles.
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
      "resolution": 0.8,
      "binmode": "true",
      "bounds": "([$XMIN,$XMAX],[$YMIN,$YMAX])"
    }

  ]
}
EOF

    echo "🔹 Extraction + rasterisation..."

    pdal pipeline "$PIPELINE"

    # ========================================================
    # ÉTAPE 2 — FILTRAGE DU BRUIT
    # ========================================================
    #
    # Suppression des groupes isolés :
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
        -st 3 \
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
    #   ~3 géométries MULTIPOLYGON
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

        WHERE DN IN (3,4,5)

        GROUP BY DN
        "

    # ========================================================
    # ÉTAPE 5 — FUSION INCRÉMENTALE
    # ========================================================
    #
    # On accumule simplement les géométries
    # sans dissolve global à chaque dalle.
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

    echo "✅ Tuile terminée"

done

# ============================================================
# DISSOLVE GLOBAL FINAL
# ============================================================
#
# Dissolve unique exécuté UNE SEULE FOIS.
#
# Charge estimée :
#
#   ~6000 dalles
#   × 3 géométries
#   ≈ 18000 géométries
#
# Ce volume reste gérable.
#
# ============================================================

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

# ============================================================
# REMPLACEMENT FINAL
# ============================================================

mv "$TMP_FINAL" "$FINAL_GPKG"

# ============================================================
# FIN
# ============================================================

echo ""
echo "=================================================="
echo "✅ TRAITEMENT TERMINÉ"
echo "=================================================="
