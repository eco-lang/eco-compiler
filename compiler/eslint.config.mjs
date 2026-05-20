import { defineConfig, globalIgnores } from "eslint/config";
import globals from "globals";
import js from "@eslint/js";


export default defineConfig([
  globalIgnores([
    "bin/guida.js",
    "bin/guida.min.js",
    "lib/guida.js",
    "lib/guida.min.js",
    "elm-stuff",
    "guida-stuff",
  ]),
  { files: ["**/*.{js,mjs,cjs}"] },
  { files: ["**/*.js"], languageOptions: { sourceType: "commonjs" } },
  { files: ["bin/**/*.{js,mjs,cjs}"], languageOptions: { globals: globals.node } },
  { files: ["lib/index.js"], languageOptions: { globals: { ...globals.browser, ...globals.node } } },
  { files: ["try/**/*.{js,mjs,cjs}"], languageOptions: { globals: { ...globals.browser, ...globals.node } } },
  { files: ["scripts/*.js"], languageOptions: { globals: globals.node } },
  {
    files: ["**/*.{js,mjs,cjs}"],
    plugins: { js },
    extends: ["js/recommended"],
    rules: {
      "no-unused-vars": ["error", {
        "argsIgnorePattern": "^_",
        "caughtErrorsIgnorePattern": "^_"
      }]
    }
  },
]);