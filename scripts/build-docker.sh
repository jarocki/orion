#!/bin/bash
mkdir -p orionx-docker/{scripts,docs,data/samples,theme/wallpapers,analysis}
# Copy all the script files into their respective locations
cd orionx-docker || exit 1
docker-compose up -d
docker exec -it orionx-phoenix bash