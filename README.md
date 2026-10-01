Build Instructions:

1. Download IntelliJ IDEA 2019.3.5 without JBR and extracted to the working directory.
2. In the working directory, run `git clone -b openjdk https://github.com/wangyenshu/recipes.git`
3. Place `build-idea.sh`,`patch-idea.sh`,`package-site.py`,`index.html`,`coi-serviceworker.js` in `recipes/`
4. Run `cd recipes`
5. Run `pixi run -e rattler-build-env build-emscripten-wasm32-pkg recipes/recipes_emscripten/x11-wasm`
6. Run `pixi run -e rattler-build-env build-emscripten-wasm32-pkg recipes/recipes_emscripten/openjdk21`
7. Run `CH="-c file://$PWD/output -c https://repo.prefix.dev/emscripten-forge-4x -c conda-forge"`
8. Run `micromamba create -y -p ./javaenv --platform emscripten-wasm32 $CH openjdk21`
9. Run `micromamba create -y -p ./emenv $CH emscripten_emscripten-wasm32=4.0.9`
10. Run `bash patch-idea.sh`
11. Run `bash build-idea.sh`
12. Run `python3 package-site.py`

The web assets will be in `site` directory.

You may need to adjust the path of intellij in `patch-idea.sh` and `build-idea.sh`.
