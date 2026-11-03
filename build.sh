set -e
mkdir -p app/assets/module
rm -f app/assets/module/zyrox-module.zip unsigned.apk
(cd module && zip -q -X -r ../app/assets/module/zyrox-module.zip .)
(cd app && zip -q -X -0 ../unsigned.apk resources.arsc \
  && zip -q -X -r ../unsigned.apk . -x resources.arsc)
zipalign -f -p 4 unsigned.apk aligned.apk
apksigner sign --ks key.jks --ks-pass env:KS_PASS \
  --out Zai-Turbo.apk aligned.apk
