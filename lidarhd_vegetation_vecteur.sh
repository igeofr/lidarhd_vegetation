#!/bin/bash

# ============================================================
# EXTRACTION ET VECTORISATION DE LA VÉGÉTATION LiDAR
# ============================================================
#
# OBJECTIF
# --------
# Produire une couche vectorielle de végétation à partir
# de dalles LiDAR (.laz) en conservant uniquement :
#
#   3 = végétation basse
#   4 = végétation moyenne
#   5 = végétation haute
#
# PIPELINE
# --------
#
#   LAZ
#    ↓
#   filtre Classification[3:5]
#    ↓
#   rasterisation PDAL
#    ↓
#   polygonisation GDAL
#    ↓
#   dissolve local par dalle
#    ↓
#   fusion incrémentale globale
#
# SORTIE
# -------
#
#   vegetation_occitanie_dissolved.gpkg
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
# VÉRIFICATION DES DÉPENDANCES
# ============================================================

command -v pdal >/dev/null 2>&1 || {
    echo "❌ PDAL non installé"
    exit 1
}

command -v ogr2ogr >/dev/null 2>&1 || {
    echo "❌ GDAL/OGR non installé"
    exit 1
}

command -v gdal_polygonize.py >/dev/null 2>&1 || {
    echo "❌ gdal_polygonize.py absent"
    exit 1
}

# ============================================================
# OPTIMISATIONS GDAL / SQLITE
# ============================================================

# Utilisation de tous les CPU
export GDAL_NUM_THREADS=ALL_CPUS

# Optimisations SQLite / GeoPackage
export OGR_SQLITE_SYNCHRONOUS=OFF
export OGR_SQLITE_CACHE=2048
export OGR_SQLITE_PRAGMA="journal_mode=OFF,temp_store=MEMORY"

# ============================================================
# FICHIER FINAL
# ============================================================

DISSOLVED_GPKG="$OUTPUT_DIR/vegetation_occitanie_dissolved.gpkg"

# Suppression ancienne version
rm -f "$DISSOLVED_GPKG"

# ============================================================
# GESTION DU CAS "AUCUN FICHIER"
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
    # FICHIERS TEMPORAIRES
    # ========================================================

    PIPELINE="$OUTPUT_DIR/pipeline_${BASENAME}.json"

    RASTER="$OUTPUT_DIR/${BASENAME}_classification.tif"

    POLYGONS="$OUTPUT_DIR/${BASENAME}_polygons.gpkg"

    POLYGONS_CLASS="$OUTPUT_DIR/${BASENAME}_polygons_classified.gpkg"

    TMP_DISSOLVE="$OUTPUT_DIR/tmp_dissolve.gpkg"

    # ========================================================
    # ÉTAPE 1
    # EXTRACTION + RASTERISATION
    # ========================================================
    #
    # Extraction directe des classes :
    #
    #   3 = basse
    #   4 = moyenne
    #   5 = haute
    #
    # puis rasterisation de la classification.
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
      "resolution": 0.5,
      "window_size": 0
    }

  ]
}
EOF

    echo "🔹 Extraction + rasterisation..."

    pdal pipeline "$PIPELINE"

    # ========================================================
    # ÉTAPE 2
    # POLYGONISATION
    # ========================================================
    #
    # Conversion raster → polygones
    #
    # ========================================================

    echo "🔹 Polygonisation..."

    gdal_polygonize.py \
        "$RASTER" \
        -f GPKG \
        "$POLYGONS" \
        polygons

    # ========================================================
    # ÉTAPE 3
    # DISSOLVE LOCAL PAR DALLE
    # ========================================================
    #
    # Réduction drastique du nombre de géométries :
    #
    # milliers de polygones
    #            ↓
    # ~3 MULTIPOLYGON par dalle
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
        -sql "
        SELECT

            DN AS classification,

            CASE
                WHEN DN = 3 THEN 'basse'
                WHEN DN = 4 THEN 'moyenne'
                WHEN DN = 5 THEN 'haute'
            END AS classe_vegetation,

            ST_Multi(
                ST_Union(geom)
            ) AS geom

        FROM polygons

        WHERE DN IN (3,4,5)

        GROUP BY DN
        "

    # ========================================================
    # ÉTAPE 4
    # FUSION INCRÉMENTALE GLOBALE
    # ========================================================
    #
    # Fusion progressive des dalles :
    #
    #   - append des géométries
    #   - mini dissolve global
    #
    # Très performant car :
    #
    #   seulement quelques géométries
    #   manipulées à chaque itération.
    #
    # ========================================================

    echo "🔹 Fusion incrémentale..."

    # --------------------------------------------------------
    # PREMIÈRE DALLE
    # --------------------------------------------------------

    if [ ! -f "$DISSOLVED_GPKG" ]; then

        echo "🔹 Initialisation couche finale..."

        cp "$POLYGONS_CLASS" "$DISSOLVED_GPKG"

    # --------------------------------------------------------
    # DALLES SUIVANTES
    # --------------------------------------------------------

    else

        rm -f "$TMP_DISSOLVE"

        # ----------------------------------------------------
        # Append des nouvelles géométries
        # ----------------------------------------------------

        ogr2ogr \
            -f GPKG \
            -update \
            -append \
            "$DISSOLVED_GPKG" \
            "$POLYGONS_CLASS" \
            -nln vegetation

        # ----------------------------------------------------
        # Mini dissolve global
        # ----------------------------------------------------

        ogr2ogr \
            -f GPKG \
            "$TMP_DISSOLVE" \
            "$DISSOLVED_GPKG" \
            -nln vegetation \
            -nlt MULTIPOLYGON \
            -lco GEOMETRY_NAME=geom \
            -dialect sqlite \
            -sql "
            SELECT

                classification,

                classe_vegetation,

                ST_Multi(
                    ST_Union(geom)
                ) AS geom

            FROM vegetation

            GROUP BY classification, classe_vegetation
            "

        # ----------------------------------------------------
        # Remplacement du résultat final
        # ----------------------------------------------------

        mv "$TMP_DISSOLVE" "$DISSOLVED_GPKG"

    fi

    # ========================================================
    # ÉTAPE 5
    # NETTOYAGE
    # ========================================================

    echo "🔹 Nettoyage..."

    rm -f \
        "$PIPELINE" \
        "$RASTER" \
        "$POLYGONS"

    echo "✅ Tuile terminée : $BASENAME"

done

# ============================================================
# FIN
# ============================================================

echo ""
echo "=================================================="
echo "✅ TRAITEMENT TERMINÉ"
echo "=================================================="
