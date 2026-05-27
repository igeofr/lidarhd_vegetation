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
#   filtrage
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

command -v gdal_sieve.py >/dev/null 2>&1 || {
    echo "❌ gdal_sieve.py absent"
    exit 1
}

# ============================================================
# OPTIMISATIONS GDAL / SQLITE
# ============================================================

export GDAL_NUM_THREADS=ALL_CPUS

export OGR_SQLITE_SYNCHRONOUS=OFF
export OGR_SQLITE_CACHE=2048
export OGR_SQLITE_PRAGMA="journal_mode=OFF,temp_store=MEMORY"

# ============================================================
# FICHIER FINAL
# ============================================================

DISSOLVED_GPKG="$OUTPUT_DIR/vegetation_occitanie_dissolved.gpkg"

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
    # RECONSTRUCTION EMPRISE 1 KM
    # ========================================================
    #
    # Exemple :
    #
    #   0671_6296
    #
    # devient :
    #
    #   xmin = 671000
    #   ymin = 6296000
    #
    # ========================================================

    TILE_X=$(echo "$BASENAME" | grep -oE '[0-9]{4}_[0-9]{4}' | cut -d'_' -f1)

    TILE_Y=$(echo "$BASENAME" | grep -oE '[0-9]{4}_[0-9]{4}' | cut -d'_' -f2)

    if [ -z "$TILE_X" ] || [ -z "$TILE_Y" ]; then
        echo "❌ Impossible de lire les coordonnées : $BASENAME"
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

    POLYGONS="$OUTPUT_DIR/${BASENAME}_polygons.gpkg"

    POLYGONS_CLASS="$OUTPUT_DIR/${BASENAME}_polygons_classified.gpkg"

    TMP_DISSOLVE="$OUTPUT_DIR/tmp_dissolve.gpkg"

    SIEVE_RASTER="$OUTPUT_DIR/${BASENAME}_classification_sieved.tif"

    # ========================================================
    # ÉTAPE 1
    # EXTRACTION + RASTERISATION
    # ========================================================
    #
    # Extraction des classes :
    #
    #   3 = basse
    #   4 = moyenne
    #   5 = haute
    #
    # Raster directement borné à l’emprise IGN
    # pour éviter tout débordement inter-dalles.
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
      "binmode": "true",
      "bounds": "([$XMIN,$XMAX],[$YMIN,$YMAX])"
    }

  ]
}
EOF

    echo "🔹 Extraction + rasterisation..."

    pdal pipeline "$PIPELINE"

    # ========================================================
    # ÉTAPE 2
    # FILTRAGE DES PETITES ENTITÉS
    # ========================================================
    #
    # Suppression des groupes isolés :
    #
    #   - 1 pixel
    #   - 2 pixels
    #
    # Permet de :
    #
    #   - réduire le bruit
    #   - accélérer la polygonisation
    #   - réduire fortement le nombre de géométries
    #
    # ========================================================

    echo "🔹 Filtrage raster (sieve)..."

    gdal_sieve.py \
        -st 3 \
        -8 \
        "$RASTER" \
        "$SIEVE_RASTER"

    # ========================================================
    # ÉTAPE 3
    # POLYGONISATION
    # ========================================================

    echo "🔹 Polygonisation..."

    gdal_polygonize.py \
        "$SIEVE_RASTER" \
        -f GPKG \
        "$POLYGONS" \
        polygons

    # ========================================================
    # ÉTAPE 4
    # DISSOLVE LOCAL PAR DALLE
    # ========================================================
    #
    # Réduction drastique :
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
        -clipsrc "$XMIN" "$YMIN" "$XMAX" "$YMAX" \
        -sql "
        WITH dissolved AS (

            SELECT

                DN AS classification,

                CASE
                    WHEN DN = 3 THEN 'basse'
                    WHEN DN = 4 THEN 'moyenne'
                    WHEN DN = 5 THEN 'haute'
                END AS classe_vegetation,

                ST_Multi(

                    ST_CollectionExtract(

                        ST_MakeValid(

                            ST_UnaryUnion(
                                ST_Collect(geom)
                            )

                        ),

                        3

                    )

                ) AS geom

            FROM polygons

            WHERE
                DN IN (3,4,5)
                AND geom IS NOT NULL

            GROUP BY DN

        )

        SELECT *

        FROM dissolved

        WHERE
            geom IS NOT NULL
            AND GeometryType(geom) IN (
                'POLYGON',
                'MULTIPOLYGON'
            )
        "

    # ========================================================
    # ÉTAPE 5
    # FUSION INCRÉMENTALE GLOBALE
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
        echo '🔹 Append des nouvelles géométries'
        ogr2ogr \
            -f GPKG \
            -update \
            -append \
            "$DISSOLVED_GPKG" \
            "$POLYGONS_CLASS" \
            -nln vegetation \
            -nlt MULTIPOLYGON \
            -lco GEOMETRY_NAME=geom \
            -lco SPATIAL_INDEX=YES

        # ----------------------------------------------------
        # Mini dissolve global
        # ----------------------------------------------------
        echo '🔹 Mini dissolve global'
        ogr2ogr \
            -f GPKG \
            "$TMP_DISSOLVE" \
            "$DISSOLVED_GPKG" \
            -nln vegetation \
            -nlt MULTIPOLYGON \
            -lco GEOMETRY_NAME=geom \
            -lco SPATIAL_INDEX=YES \
            -dialect sqlite \
            -sql "
            SELECT
                classification,
                classe_vegetation,
                ST_Multi(

                    ST_CollectionExtract(

                        ST_MakeValid(

                            ST_UnaryUnion(
                                ST_Collect(geom)
                            )

                        ),

                        3

                    )

                ) AS geom
            FROM vegetation
            WHERE geom IS NOT NULL
            GROUP BY classification, classe_vegetation
            "

        # ----------------------------------------------------
        # Remplacement résultat final
        # ----------------------------------------------------

        mv "$TMP_DISSOLVE" "$DISSOLVED_GPKG"

    fi

    # ========================================================
    # ÉTAPE 6
    # NETTOYAGE
    # ========================================================

    echo "🔹 Nettoyage..."

    rm -f \
        "$PIPELINE" \
        "$RASTER" \
        "$POLYGONS" \
        "$SIEVE_RASTER"

    echo "✅ Tuile terminée : $BASENAME"

done

# ============================================================
# FIN
# ============================================================

echo ""
echo "=================================================="
echo "✅ TRAITEMENT TERMINÉ"
echo "=================================================="
