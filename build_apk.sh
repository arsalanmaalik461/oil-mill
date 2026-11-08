#!/bin/bash
export JAVA_HOME=$HOME/tools/jdk
export ANDROID_HOME=$HOME/tools/android-sdk
export GRADLE_USER_HOME=$HOME/.gradle
export PATH=$HOME/tools/jdk/bin:$HOME/tools/flutter/bin:$PATH
cd ~/workspace/namat_oil_mill
flutter build apk --release
echo "BUILD_EXIT=$?"
ls -la build/app/outputs/flutter-apk/ 2>/dev/null
