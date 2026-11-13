#!/usr/bin/env bash
# Ajusta o projeto Android gerado pelo `flutter create` para usar o Firebase.
# Roda no GitHub Actions logo depois do `flutter create`.
set -euo pipefail
cd "$(dirname "$0")/.."

if [ ! -f android/app/google-services.json ]; then
  echo "::error::Falta app/android/app/google-services.json (baixe do console do Firebase)."
  exit 1
fi

SETTINGS=android/settings.gradle.kts
APP=android/app/build.gradle.kts
MANIFEST=android/app/src/main/AndroidManifest.xml

if [ -f "$SETTINGS" ] && [ -f "$APP" ]; then
  # 1) plugin google-services declarado no settings
  if ! grep -q 'com.google.gms.google-services' "$SETTINGS"; then
    sed -i '/id("com.android.application")/a\    id("com.google.gms.google-services") version "4.4.2" apply false' "$SETTINGS"
  fi
  # 2) plugin aplicado no módulo app
  if ! grep -q 'com.google.gms.google-services' "$APP"; then
    sed -i '/id("dev.flutter.flutter-gradle-plugin")/a\    id("com.google.gms.google-services")' "$APP"
  fi
  # 3) minSdk 24 (exigido pelos plugins Firebase / câmera)
  sed -i -E 's/minSdk *= *flutter\.minSdkVersion/minSdk = 24/' "$APP"
else
  # Projetos em Groovy (versões antigas do Flutter)
  SETTINGS=android/settings.gradle
  APP=android/app/build.gradle
  if ! grep -q 'com.google.gms.google-services' "$SETTINGS"; then
    sed -i '/id "com.android.application"/a\    id "com.google.gms.google-services" version "4.4.2" apply false' "$SETTINGS"
  fi
  if ! grep -q 'com.google.gms.google-services' "$APP"; then
    sed -i '/id "dev.flutter.flutter-gradle-plugin"/a\    id "com.google.gms.google-services"' "$APP"
  fi
  sed -i -E 's/minSdk(Version)? *=? *flutter\.minSdkVersion/minSdkVersion 24/' "$APP"
fi

grep -q 'com.google.gms.google-services' "$SETTINGS" || { echo "::error::Falhou ao inserir plugin em $SETTINGS"; cat "$SETTINGS"; exit 1; }
grep -q 'com.google.gms.google-services' "$APP" || { echo "::error::Falhou ao inserir plugin em $APP"; cat "$APP"; exit 1; }

# Nome do app no celular
sed -i 's/android:label="circuito"/android:label="Circuito de Descobertas"/' "$MANIFEST"

echo "----- $SETTINGS"; cat "$SETTINGS"
echo "----- $APP"; cat "$APP"
